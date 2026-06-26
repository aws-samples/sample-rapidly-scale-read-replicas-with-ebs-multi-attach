// RocksDB REST Service — minimal HTTP server (no external HTTP library)
// Endpoints:
//   GET  /health
//   GET  /get?key=<key>
//   POST /put        body: {"key":"...","value":"..."}
//   POST /batch-put  body: {"pairs":[{"key":"k","value":"v"},...]}  (writer only, up to 1000 pairs)
//   POST /delete     body: {"key":"..."}
//   GET  /scan
//   POST /flush      (writer only)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include "rocksdb/db.h"
#include "rocksdb/options.h"

static rocksdb::DB* g_db = nullptr;
static std::atomic<bool> g_running{true};
static std::string g_mode;
static std::string g_db_path;
// Shared admin token (loaded at startup from the ADMIN_TOKEN env var, which is
// supplied via /etc/rocksdb/service.env). Required on all /admin/* endpoints.
static std::string g_admin_token;

// Max total HTTP request size (headers + body). Bounds per-connection memory and
// doubles as the Content-Length ceiling, rejecting oversized/streamed bodies (DoS).
static const size_t MAX_REQUEST_BYTES = 64 * 1024 * 1024;  // 64 MiB

// Constant-time string compare — avoids leaking the token via timing.
static bool ct_equal(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    unsigned char r = 0;
    for (size_t i = 0; i < a.size(); ++i) r = (unsigned char)(r | (a[i] ^ b[i]));
    return r == 0;
}

// Reject any value containing shell metacharacters. Allows only the characters
// used by IPs / instance-ids / volume-ids / region / cluster names, which is
// enough to make safe shell interpolation impossible.
static bool is_safe_field(const std::string& s, size_t maxlen) {
    if (s.empty() || s.size() > maxlen) return false;
    for (unsigned char c : s) {
        if (!(std::isalnum(c) || c == '.' || c == '-' || c == '_')) return false;
    }
    return true;
}

// ── JSON helpers ─────────────────────────────────────────────────────────────
static std::string esc(const std::string& s) {
    static const char* HEX = "0123456789abcdef";
    std::string r; r.reserve(s.size());
    // Iterate as unsigned so bytes >= 0x80 (binary/UTF-8) compare correctly and
    // pass through untouched. All JSON control chars (U+0000–U+001F) MUST be
    // escaped or the response is invalid JSON — a raw \r, \t, NUL, etc. in a
    // stored key/value would otherwise break the client's parser.
    for (unsigned char c : s) {
        switch (c) {
            case '"':  r += "\\\""; break;
            case '\\': r += "\\\\"; break;
            case '\b': r += "\\b";  break;
            case '\f': r += "\\f";  break;
            case '\n': r += "\\n";  break;
            case '\r': r += "\\r";  break;
            case '\t': r += "\\t";  break;
            default:
                if (c < 0x20) {                 // other control chars → \u00XX
                    r += "\\u00";
                    r += HEX[(c >> 4) & 0xF];
                    r += HEX[c & 0xF];
                } else {
                    r += static_cast<char>(c);
                }
        }
    }
    return r;
}
static std::string jkv(const std::string& k,const std::string& v){
    return "{\"key\":\""+esc(k)+"\",\"value\":\""+esc(v)+"\"}";
}
static std::string jstr(const std::string& k,const std::string& v){
    return "{\""+k+"\":\""+esc(v)+"\"}";
}
static std::string jfield(const std::string& body,const std::string& f){
    auto p=body.find("\""+f+"\""); if(p==std::string::npos)return "";
    p=body.find(':',p); if(p==std::string::npos)return "";
    p=body.find('"',p+1); if(p==std::string::npos)return "";
    auto e=body.find('"',p+1);
    while(e!=std::string::npos&&body[e-1]=='\\')e=body.find('"',e+1);
    if(e==std::string::npos)return "";
    return body.substr(p+1,e-p-1);
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────
static std::string http_resp(int code, const std::string& body) {
    std::string status = code==200?"200 OK":code==403?"403 Forbidden":
                         code==404?"404 Not Found":"500 Internal Server Error";
    return "HTTP/1.1 "+status+"\r\nContent-Type: application/json\r\n"
           "Content-Length: "+std::to_string(body.size())+"\r\nConnection: close\r\n\r\n"+body;
}

// ── Catch-up thread (readonly only) ──────────────────────────────────────────
static void catch_up_thread() {
    while (g_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        if (g_db) g_db->TryCatchUpWithPrimary();
    }
}

// ── Request handler ───────────────────────────────────────────────────────────
static std::string handle(const std::string& method, const std::string& path,
                          const std::string& query, const std::string& body,
                          const std::string& bearer) {
    // Gate all admin/lifecycle endpoints AND cluster-topology endpoints behind the
    // shared admin token. /cluster/* leaks internal private IPs and node IDs, so it
    // must not be reachable unauthenticated. Fails closed: if no token is
    // configured, every gated call is rejected.
    if (path.rfind("/admin/", 0) == 0 || path.rfind("/cluster/", 0) == 0) {
        if (g_admin_token.empty() || !ct_equal(bearer, g_admin_token))
            return http_resp(403, jstr("error","forbidden"));
    }

    if (path=="/health")
        return g_db
            ? http_resp(200,"{\"status\":\"ok\",\"mode\":\""+g_mode+"\"}")
            : http_resp(503,"{\"status\":\"starting\",\"mode\":\""+g_mode+"\"}");

    if (path=="/get") {
        if(!g_db) return http_resp(503,jstr("error","db not ready"));
        auto ki=query.find("key=");
        if(ki==std::string::npos) return http_resp(400,jstr("error","missing key"));
        std::string key=query.substr(ki+4);
        auto amp=key.find('&'); if(amp!=std::string::npos) key=key.substr(0,amp);
        std::string dk; for(size_t i=0;i<key.size();i++){
            if(key[i]=='%'&&i+2<key.size()){
                int c=std::stoi(key.substr(i+1,2),nullptr,16); dk+=(char)c; i+=2;
            } else if(key[i]=='+') dk+=' '; else dk+=key[i];
        }
        std::string val;
        auto s=g_db->Get(rocksdb::ReadOptions(),dk,&val);
        if(s.ok()) return http_resp(200,jkv(dk,val));
        if(s.IsNotFound()) return http_resp(404,jstr("error","not found"));
        return http_resp(500,jstr("error",s.ToString()));
    }

    if (path=="/put") {
        if(g_mode!="readwrite") return http_resp(403,jstr("error","read-only instance"));
        auto k=jfield(body,"key"), v=jfield(body,"value");
        if(k.empty()) return http_resp(400,jstr("error","missing key"));
        auto s=g_db->Put(rocksdb::WriteOptions(),k,v);
        if(!s.ok()) return http_resp(500,jstr("error",s.ToString()));
        rocksdb::FlushOptions fo; fo.wait=false;
        g_db->Flush(fo);
        return http_resp(200,"{\"status\":\"ok\"}");
    }

    if (path=="/delete") {
        if(g_mode!="readwrite") return http_resp(403,jstr("error","read-only instance"));
        auto k=jfield(body,"key");
        if(k.empty()) return http_resp(400,jstr("error","missing key"));
        auto s=g_db->Delete(rocksdb::WriteOptions(),k);
        if(!s.ok()) return http_resp(500,jstr("error",s.ToString()));
        rocksdb::FlushOptions fo; fo.wait=false;
        g_db->Flush(fo);
        return http_resp(200,"{\"status\":\"ok\"}");
    }

    if (path=="/scan") {
        if(!g_db) return http_resp(503,jstr("error","db not ready"));
        // Bounded scan: ?limit=N (default 1000, clamped 1..10000) and optional
        // ?after=<url-encoded key> cursor (exclusive) for pagination. Caps per-request
        // memory, response size, and IO — prevents unbounded full-table dumps/DoS.
        auto qparam = [&](const std::string& k)->std::string{
            auto p=query.find(k+"="); if(p==std::string::npos) return "";
            p+=k.size()+1; auto e=query.find('&',p);
            return query.substr(p, e==std::string::npos?std::string::npos:e-p);
        };
        long limit=1000;
        try { std::string ls=qparam("limit"); if(!ls.empty()) limit=std::stol(ls); } catch(...) { limit=1000; }
        if(limit<1) limit=1; if(limit>10000) limit=10000;
        std::string after; {
            std::string raw=qparam("after");
            for(size_t i=0;i<raw.size();i++){
                if(raw[i]=='%'&&i+2<raw.size()){ int c=std::stoi(raw.substr(i+1,2),nullptr,16); after+=(char)c; i+=2; }
                else if(raw[i]=='+') after+=' '; else after+=raw[i];
            }
        }
        auto* it=g_db->NewIterator(rocksdb::ReadOptions());
        if(!after.empty()){ it->Seek(after); if(it->Valid()&&it->key().ToString()==after) it->Next(); }
        else it->SeekToFirst();
        std::string out="{\"records\":["; bool first=true; long n=0; std::string last;
        for(; it->Valid() && n<limit; it->Next()){
            if(!first)out+=",";
            last=it->key().ToString();
            out+=jkv(last,it->value().ToString());
            first=false; n++;
        }
        bool more=it->Valid();
        delete it;
        out+="]";
        if(more) out+=",\"next\":\""+esc(last)+"\"";
        out+="}";
        return http_resp(200,out);
    }

    if (path=="/flush") {
        if(g_mode!="readwrite") return http_resp(403,jstr("error","read-only instance"));
        rocksdb::FlushOptions fo; fo.wait=true;
        auto s=g_db->Flush(fo);
        return s.ok()?http_resp(200,"{\"status\":\"ok\"}"):http_resp(500,jstr("error",s.ToString()));
    }

    if (path=="/batch-put") {
        if(g_mode!="readwrite") return http_resp(403,jstr("error","read-only instance"));
        if(!g_db) return http_resp(503,jstr("error","db not ready"));
        rocksdb::WriteBatch batch;
        int count = 0;
        size_t pos = 0;
        while (true) {
            auto ko = body.find("\"key\"", pos);
            if (ko == std::string::npos) break;
            auto kp = body.find('"', ko + 5); if (kp == std::string::npos) break;
            auto ke = body.find('"', kp + 1);
            while (ke != std::string::npos && body[ke-1] == '\\') ke = body.find('"', ke+1);
            if (ke == std::string::npos) break;
            std::string k = body.substr(kp+1, ke-kp-1);
            auto vo = body.find("\"value\"", ke);
            if (vo == std::string::npos) break;
            auto vp = body.find('"', vo + 7); if (vp == std::string::npos) break;
            auto ve = body.find('"', vp + 1);
            while (ve != std::string::npos && body[ve-1] == '\\') ve = body.find('"', ve+1);
            if (ve == std::string::npos) break;
            std::string v = body.substr(vp+1, ve-vp-1);
            batch.Put(k, v);
            count++;
            // Enforce the documented 1000-pair cap to bound batch memory/CPU.
            if (count > 1000) return http_resp(400, jstr("error","batch exceeds 1000 pairs"));
            pos = ve + 1;
        }
        if (count == 0) return http_resp(400, jstr("error","no pairs found"));
        auto s = g_db->Write(rocksdb::WriteOptions(), &batch);
        return s.ok()
            ? http_resp(200, "{\"status\":\"ok\",\"written\":" + std::to_string(count) + "}")
            : http_resp(500, jstr("error", s.ToString()));
    }

    auto popen_str = [](const char* cmd) -> std::string {
        FILE* f = popen(cmd, "r"); if (!f) return "";
        std::string out; char buf[256];
        while (fgets(buf, sizeof(buf), f)) out += buf;
        pclose(f); return out;
    };

    if (path=="/cluster/nodes") {
        std::string raw = popen_str("pcs status nodes corosync 2>/dev/null");
        std::string nodes_json = "[";
        int count = 0; bool first = true;
        std::istringstream ss(raw);
        std::string line;
        while (std::getline(ss, line)) {
            auto pos = line.find("Online:");
            if (pos == std::string::npos) continue;
            std::istringstream ls(line.substr(pos + 7));
            std::string ip;
            while (ls >> ip) {
                if (!first) nodes_json += ",";
                nodes_json += "\"" + ip + "\"";
                first = false; count++;
            }
        }
        nodes_json += "]";
        return http_resp(200, "{\"online\":" + std::to_string(count) + ",\"nodes\":" + nodes_json + "}");
    }

    if (path=="/cluster/nodeids") {
        std::string raw = popen_str("grep -E 'ring0_addr:|nodeid:' /etc/corosync/corosync.conf 2>/dev/null");
        std::string map_json = "{";
        bool first = true;
        std::istringstream ss(raw);
        std::string line, current_ip;
        while (std::getline(ss, line)) {
            auto ip_pos = line.find("ring0_addr:");
            if (ip_pos != std::string::npos) {
                std::istringstream ls(line.substr(ip_pos + 11));
                ls >> current_ip;
            }
            auto id_pos = line.find("nodeid:");
            if (id_pos != std::string::npos && !current_ip.empty()) {
                std::istringstream ls(line.substr(id_pos + 7));
                std::string nid; ls >> nid;
                if (!first) map_json += ",";
                map_json += "\"" + current_ip + "\":" + nid;
                first = false;
                current_ip = "";
            }
        }
        map_json += "}";
        return http_resp(200, "{\"map\":" + map_json + "}");
    }

    // Promote this instance from readonly to readwrite (writer role).
    // Uses systemd-run to detach the promote script from rocksdb.service's process group,
    // so it survives when rocksdb.service is stopped during cluster re-setup.
    // Promote this instance from readonly to readwrite (writer role).
    // Simple approach: reader is already in the cluster with GFS2 mounted.
    // Just switch mode, remove LOCK, restart service, start watcher.
    if (path=="/admin/promote" && method=="POST") {
        // Update SSM writer-instance-id IMMEDIATELY to prevent race with new instances booting
        popen_str("bash -c '"
            "REGION=$(grep -oP \"REGION=\\K.*\" /etc/rocksdb/cluster.env 2>/dev/null || echo us-east-1); "
            "CLUSTER=$(grep -oP \"CLUSTER_NAME=\\K.*\" /etc/rocksdb/cluster.env 2>/dev/null || echo rocksdb-cluster); "
            "TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds:60 2>/dev/null); "
            "INST=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null); "
            "/snap/bin/aws ssm put-parameter --name /${CLUSTER}/writer-instance-id --type String --value ${INST} --overwrite --region ${REGION} 2>/dev/null || true"
            "'");
        // Switch mode and remove LOCK synchronously (before service restart kills us)
        popen_str("sudo sed -i s/MODE=readonly/MODE=readwrite/ /etc/rocksdb/service.env");
        popen_str("sudo rm -f /data/rocksdb/db/LOCK");
        // Use systemd-run to restart the service in a new transient unit — this survives
        // the current rocksdb.service process being killed by the restart
        popen_str("systemd-run --unit=rocksdb-promote-restart --no-block "
                  "bash -c 'sleep 1 && systemctl restart rocksdb.service'");
        return http_resp(200, "{\"status\":\"ok\",\"action\":\"promoting\"}");
    }

    // Bootstrap a single-node cluster on this reader (writerless recovery).
    // POST /admin/bootstrap  body: {"priv_ip":"...","instance_id":"...","region":"...","volume_id":"...","cluster_name":"..."}
    // Wipes stale cluster state, sets up corosync/pacemaker/DLM/GFS2, switches to readwrite.
    if (path=="/admin/bootstrap" && method=="POST") {
        auto priv_ip = jfield(body, "priv_ip");
        auto inst_id = jfield(body, "instance_id");
        auto region  = jfield(body, "region");
        auto vol_id  = jfield(body, "volume_id");
        auto cluster = jfield(body, "cluster_name");
        if (priv_ip.empty() || inst_id.empty() || region.empty() || vol_id.empty() || cluster.empty())
            return http_resp(400, jstr("error", "missing priv_ip, instance_id, region, volume_id, or cluster_name"));
        // Validate every field before it is interpolated into a shell script.
        // Blocks command injection via shell metacharacters.
        if (!is_safe_field(priv_ip, 15) || !is_safe_field(inst_id, 32) ||
            !is_safe_field(region, 20) || !is_safe_field(vol_id, 30) ||
            !is_safe_field(cluster, 40))
            return http_resp(400, jstr("error", "invalid field value"));
        std::string vol_serial = vol_id;
        vol_serial.erase(std::remove(vol_serial.begin(), vol_serial.end(), '-'), vol_serial.end());
        std::string dev = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_" + vol_serial;
        std::string script =
            "#!/bin/bash\n"
            "set -uo pipefail\n"
            "exec > /var/log/rocksdb-bootstrap.log 2>&1\n"
            "echo '==> Bootstrap starting'\n"
            "systemctl stop rocksdb.service 2>/dev/null || true\n"
            "systemctl stop cluster-watcher.service 2>/dev/null || true\n"
            "killall -9 corosync pacemakerd pacemaker-controld pacemaker-attrd "
            "pacemaker-fenced pacemaker-schedulerd pacemaker-based 2>/dev/null || true\n"
            "systemctl stop pacemaker corosync 2>/dev/null || true\n"
            "rm -f /etc/corosync/corosync.conf\n"
            "rm -rf /var/lib/pacemaker/cib/ && mkdir -p /var/lib/pacemaker/cib\n"
            "rm -rf /var/lib/corosync/ && mkdir -p /var/lib/corosync\n"
            "rm -rf /var/lib/pcsd/ && mkdir -p /var/lib/pcsd\n"
            "AUTH=$(/snap/bin/aws ssm get-parameter --name /" + cluster + "/corosync-authkey "
            "--with-decryption --query 'Parameter.Value' --output text --region " + region + ")\n"
            "echo \"$AUTH\" | base64 -d > /etc/corosync/authkey\n"
            "/snap/bin/aws ssm get-parameter --name /" + cluster + "/pacemaker-authkey "
            "--with-decryption --query 'Parameter.Value' --output text --region " + region +
            " | base64 -d > /etc/pacemaker/authkey\n"
            "chmod 400 /etc/corosync/authkey /etc/pacemaker/authkey\n"
            "systemctl start pcsd\n"
            "HPW=$(/snap/bin/aws ssm get-parameter --name /" + cluster + "/hacluster-password "
            "--with-decryption --query 'Parameter.Value' --output text --region " + region + ")\n"
            "pcs host auth " + priv_ip + " -u hacluster -p \"$HPW\"\n"
            "pcs cluster setup " + cluster + " " + priv_ip + " --force\n"
            "pcs cluster start --all\n"
            "pcs cluster enable --all\n"
            "sleep 10\n"
            "pcs property set stonith-enabled=true\n"
            "pcs property set no-quorum-policy=ignore\n"
            "pcs cluster config update totem token=30000 2>/dev/null || true\n"
            "pcs stonith create clusterfence fence_aws region=" + region +
            " pcmk_host_map=\"" + priv_ip + ":" + inst_id + "\""
            " power_timeout=240 pcmk_reboot_timeout=480 pcmk_reboot_retries=4\n"
            "pcs resource create dlm ocf:pacemaker:controld "
            "op monitor interval=30s on-fail=fence clone interleave=true\n"
            "sleep 15\n"
            "pcs resource create gfs2fs ocf:heartbeat:Filesystem "
            "device=" + dev + " directory=/data/rocksdb fstype=gfs2 options=noatime "
            "op monitor interval=10s on-fail=fence clone interleave=true\n"
            "pcs constraint order start dlm-clone then gfs2fs-clone\n"
            "pcs resource update gfs2fs op start timeout=300s op stop timeout=300s "
            "op monitor timeout=300s interval=30s\n"
            "for _w in $(seq 1 60); do mountpoint -q /data/rocksdb && break; sleep 3; done\n"
            "mkdir -p /data/rocksdb/db && chmod 777 /data/rocksdb/db\n"
            "rm -f /data/rocksdb/db/LOCK\n"
            "[ -f /data/rocksdb/.next_nodeid ] || echo 2 > /data/rocksdb/.next_nodeid\n"
            "chmod 666 /data/rocksdb/.next_nodeid 2>/dev/null || true\n"
            "/snap/bin/aws ssm put-parameter --name /" + cluster + "/corosync-authkey "
            "--type SecureString --value \"$(base64 -w0 /etc/corosync/authkey)\" "
            "--overwrite --region " + region + " || true\n"
            "/snap/bin/aws ssm put-parameter --name /" + cluster + "/pacemaker-authkey "
            "--type SecureString --value \"$(base64 -w0 /etc/pacemaker/authkey)\" "
            "--overwrite --region " + region + " || true\n"
            "for N in $(cibadmin --query --xpath '//node' 2>/dev/null "
            "| grep -oP 'uname=\"\\K[^\"]+' || true); do "
            "echo \"$N\" | grep -q '" + priv_ip + "' || crm_node --force --remove \"$N\" 2>/dev/null || true; done\n"
            "sed -i 's/MODE=readonly/MODE=readwrite/' /etc/rocksdb/service.env\n"
            "systemctl restart rocksdb.service\n"
            "echo '==> Bootstrap complete'\n";
        FILE* f = fopen("/tmp/rocksdb_bootstrap.sh", "w");
        if (f) { fputs(script.c_str(), f); fclose(f); }
        popen_str("bash -c 'sudo bash /tmp/rocksdb_bootstrap.sh' &");
        return http_resp(200, "{\"status\":\"ok\",\"action\":\"bootstrapping\"}");
    }

    // Demote this instance from readwrite to readonly (reader role)
    if (path=="/admin/demote" && method=="POST") {
        popen_str("sudo sed -i 's/MODE=readwrite/MODE=readonly/' /etc/rocksdb/service.env");
        // Use systemd-run so the restart survives rocksdb.service being killed
        popen_str("systemd-run --unit=rocksdb-demote-restart --no-block "
                  "bash -c 'sleep 1 && systemctl restart rocksdb.service'");
        return http_resp(200, "{\"status\":\"ok\",\"action\":\"demoting\"}");
    }

    // Start cluster watcher service
    if (path=="/admin/start-watcher" && method=="POST") {
        popen_str("sudo systemctl enable cluster-watcher.service 2>/dev/null || true");
        popen_str("sudo systemctl restart cluster-watcher.service 2>/dev/null || true");
        return http_resp(200, "{\"status\":\"ok\",\"action\":\"watcher-started\"}");
    }

    // Gracefully leave the cluster
    if (path=="/admin/leave-cluster" && method=="POST") {
        popen_str("bash -c 'sudo pcs node standby $(hostname -I | awk \"{print \\$1}\") 2>/dev/null; sleep 3; sudo pcs cluster stop --force 2>/dev/null; sudo systemctl stop pacemaker corosync 2>/dev/null' &");
        return http_resp(200, "{\"status\":\"ok\",\"action\":\"leaving\"}");
    }

    // Return RocksDB data directory size in bytes
    if (path=="/admin/dbsize" && method=="GET") {
        long long bytes = 0;
        if (g_db) {
            std::string val;
            if (g_db->GetProperty("rocksdb.total-sst-files-size", &val)) {
                try { bytes = std::stoll(val); } catch(...) {}
            }
        }
        return http_resp(200, "{\"bytes\":" + std::to_string(bytes) + "}");
    }

    // Wipe the RocksDB database
    if (path=="/admin/resetdb" && method=="POST") {
        if(g_mode!="readwrite") return http_resp(403,jstr("error","read-only instance"));
        if (g_db) { delete g_db; g_db = nullptr; }
        system("sudo rm -rf /data/rocksdb/db && sudo mkdir -p /data/rocksdb/db && sudo chmod 777 /data/rocksdb/db");
        rocksdb::Options opts; opts.create_if_missing=true;
        auto s = rocksdb::DB::Open(opts, g_db_path, &g_db);
        if (!s.ok()) return http_resp(500, jstr("error", s.ToString()));
        return http_resp(200, "{\"status\":\"ok\",\"action\":\"db-reset\"}");
    }

    return http_resp(404,jstr("error","not found"));
}
static void handle_conn(int fd) {
  try {
    // Read full HTTP request (headers + body)
    std::string req;
    char tmp[4096];
    long content_len = -1;                 // resolved once headers are complete
    size_t headers_end = std::string::npos;
    // Read until we have headers + complete body, bounded by MAX_REQUEST_BYTES.
    while (true) {
        int n = recv(fd, tmp, sizeof(tmp), 0);
        if (n <= 0) break;
        req.append(tmp, n);
        // Hard cap total request size — prevents memory-exhaustion DoS from a
        // huge/streamed body or an oversized header.
        if (req.size() > MAX_REQUEST_BYTES) {
            std::string r = http_resp(413, jstr("error","request too large"));
            send(fd, r.c_str(), r.size(), 0); close(fd); return;
        }
        // Resolve Content-Length once, the first time headers are complete.
        if (headers_end == std::string::npos) {
            headers_end = req.find("\r\n\r\n");
            if (headers_end == std::string::npos) continue;
            auto cl_pos = req.find("Content-Length:");
            if (cl_pos == std::string::npos) cl_pos = req.find("content-length:");
            if (cl_pos != std::string::npos) {
                auto cl_end = req.find("\r\n", cl_pos);
                std::string cl = req.substr(cl_pos + 15,
                    (cl_end == std::string::npos ? req.size() : cl_end) - (cl_pos + 15));
                size_t b = cl.find_first_not_of(" \t");
                size_t e = cl.find_last_not_of(" \t");
                cl = (b == std::string::npos) ? "" : cl.substr(b, e - b + 1);
                // Reject a non-numeric Content-Length explicitly. The old code fed
                // this straight to std::stoi, whose exception, thrown in this
                // detached thread, called std::terminate() and killed the whole
                // process (a single bad request = node-wide DoS).
                if (cl.empty() || cl.find_first_not_of("0123456789") != std::string::npos) {
                    std::string r = http_resp(400, jstr("error","bad content-length"));
                    send(fd, r.c_str(), r.size(), 0); close(fd); return;
                }
                unsigned long long v = MAX_REQUEST_BYTES + 1;
                try { v = std::stoull(cl); } catch (...) { v = MAX_REQUEST_BYTES + 1; }
                if (v > MAX_REQUEST_BYTES) {
                    std::string r = http_resp(413, jstr("error","request too large"));
                    send(fd, r.c_str(), r.size(), 0); close(fd); return;
                }
                content_len = (long)v;
            } else {
                content_len = 0; // no body expected
            }
        }
        long body_received = (long)req.size() - (long)(headers_end + 4);
        if (body_received >= content_len) break;
    }
    if (req.empty()) { close(fd); return; }
    // Parse first line
    auto nl=req.find("\r\n"); if(nl==std::string::npos){close(fd);return;}
    std::istringstream fl(req.substr(0,nl));
    std::string method,full_path,ver; fl>>method>>full_path>>ver;
    std::string path=full_path, query;
    auto qi=full_path.find('?');
    if(qi!=std::string::npos){path=full_path.substr(0,qi);query=full_path.substr(qi+1);}
    // Body
    auto hend=req.find("\r\n\r\n");
    std::string body=hend!=std::string::npos?req.substr(hend+4):"";
    // Extract bearer token from the Authorization header (case-insensitive)
    std::string bearer;
    {
        std::string headers = hend!=std::string::npos ? req.substr(0,hend) : req;
        std::string lc = headers;
        for(auto& c : lc) c=(char)std::tolower((unsigned char)c);
        auto ap = lc.find("authorization:");
        if(ap!=std::string::npos){
            auto le = headers.find("\r\n", ap);
            size_t start = ap + 14; // len("authorization:")
            std::string val = headers.substr(start, (le==std::string::npos?headers.size():le)-start);
            size_t b = val.find_first_not_of(" \t");
            if(b!=std::string::npos) val=val.substr(b); else val.clear();
            if(val.size()>=7){
                std::string pfx=val.substr(0,7);
                for(auto& c: pfx) c=(char)std::tolower((unsigned char)c);
                if(pfx=="bearer ") val=val.substr(7);
            }
            size_t e = val.find_last_not_of(" \t\r\n");
            val = (e==std::string::npos) ? std::string() : val.substr(0,e+1);
            bearer = val;
        }
    }
    std::string resp=handle(method,path,query,body,bearer);
    // ── access log (audit): client · method · path · status → stdout/journald ──
    {
        char ipbuf[INET_ADDRSTRLEN] = "?";
        sockaddr_in peer{}; socklen_t pl = sizeof(peer);
        if (getpeername(fd,(sockaddr*)&peer,&pl)==0)
            inet_ntop(AF_INET,&peer.sin_addr,ipbuf,sizeof(ipbuf));
        std::string code = resp.size()>=12 ? resp.substr(9,3) : "---";
        std::cout << ipbuf << " " << method << " " << path << " " << code << std::endl;
    }
    send(fd,resp.c_str(),resp.size(),0);
    close(fd);
    return;
  } catch (const std::exception&) {
    // Never let an exception escape a detached connection thread — that calls
    // std::terminate() and kills the whole process. Fail just this connection.
    try { std::string r = http_resp(500, jstr("error","internal")); send(fd, r.c_str(), r.size(), 0); } catch (...) {}
    close(fd);
  } catch (...) {
    close(fd);
  }
}

int main(int argc, char* argv[]) {
    if(argc<3){std::cerr<<"Usage: "<<argv[0]<<" <db_path> <readwrite|readonly> [port]\n";return 1;}
    g_db_path=argv[1]; g_mode=argv[2];
    int port=argc>=4?std::stoi(argv[3]):8080;
    if (const char* t = std::getenv("ADMIN_TOKEN")) g_admin_token = t;

    rocksdb::Options opts; opts.create_if_missing=true;
    rocksdb::Status s;
    if(g_mode=="readwrite"){
        s=rocksdb::DB::Open(opts,g_db_path,&g_db);
    } else {
        std::string sec="/tmp/rocksdb_sec_"+std::to_string(getpid());
        // Wait for primary DB
        while(access((g_db_path+"/CURRENT").c_str(),F_OK)!=0){
            std::cout<<"Waiting for primary DB...\n"; std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
        s=rocksdb::DB::OpenAsSecondary(opts,g_db_path,sec,&g_db);
        if(s.ok()){g_db->TryCatchUpWithPrimary(); std::thread(catch_up_thread).detach();}
    }
    if(!s.ok()){std::cerr<<"Failed to open DB: "<<s.ToString()<<"\n";return 1;}
    std::cout<<"RocksDB service ["<<g_mode<<"] port "<<port<<" db="<<g_db_path<<"\n";

    int srv=socket(AF_INET,SOCK_STREAM,0);
    int opt=1; setsockopt(srv,SOL_SOCKET,SO_REUSEADDR,&opt,sizeof(opt));
    sockaddr_in addr{}; addr.sin_family=AF_INET; addr.sin_addr.s_addr=INADDR_ANY;
    addr.sin_port=htons(port);
    bind(srv,(sockaddr*)&addr,sizeof(addr)); listen(srv,128);

    signal(SIGTERM,[](int){g_running=false;});
    signal(SIGINT,[](int){g_running=false;});

    while(g_running){
        sockaddr_in cli{}; socklen_t cl=sizeof(cli);
        int fd=accept(srv,(sockaddr*)&cli,&cl);
        if(fd<0)continue;
        std::thread(handle_conn,fd).detach();
    }
    close(srv); delete g_db; return 0;
}
