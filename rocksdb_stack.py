import aws_cdk as cdk
from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_iam as iam,
    aws_autoscaling as autoscaling,
    aws_elasticloadbalancingv2 as elbv2,
    aws_ssm as ssm,
    aws_s3 as s3,
)
from constructs import Construct


def _read_ami_id() -> str | None:
    try:
        with open("ami_id.txt", encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


CLUSTER_NAME = "rocksdb-cluster"


class RocksDbStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs):
        super().__init__(scope, construct_id, **kwargs)

        ami_id = _read_ami_id()
        region = self.region
        az = f"{region}a"

        machine_image = (
            ec2.MachineImage.generic_linux({region: ami_id})
            if ami_id
            else ec2.MachineImage.lookup(
                name="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*",
                owners=["099720109477"],
            )
        )

        # Dedicated VPC — public subnets in 2 AZs (ALB requires 2), no NAT gateway
        # EC2/EBS stay in a single AZ (EBS Multi-Attach requirement)
        vpc = ec2.Vpc(self, "RocksDbVpc",
            max_azs=2,
            ip_addresses=ec2.IpAddresses.cidr("10.0.0.0/16"),
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                    cidr_mask=24,
                ),
            ],
            nat_gateways=0,
        )
        vpc.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        key_pair = ec2.KeyPair.from_key_pair_name(self, "KeyPair", "rocksdb-key")

        # IAM role — EC2, SSM, ASG, fencing
        role = iam.Role(self, "RocksDbRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("AmazonEC2ReadOnlyAccess"),
                # Lets the SSM agent register the instance so operators can use
                # Session Manager / send-command instead of public SSH.
                iam.ManagedPolicy.from_aws_managed_policy_name("AmazonSSMManagedInstanceCore"),
            ],
        )
        # Least-privilege inline policy (replaces the former resources="*" grant).
        # SSM is scoped to this cluster's parameter namespace, KMS is usable only
        # via SSM, and EC2 mutations are limited to instances/volumes in this
        # account+region. (ec2/autoscaling Describe* come from the managed RO policy.)
        role.add_to_policy(iam.PolicyStatement(
            sid="ClusterSsmParams",
            actions=["ssm:GetParameter", "ssm:PutParameter", "ssm:DeleteParameter"],
            resources=[f"arn:aws:ssm:{region}:{self.account}:parameter/{CLUSTER_NAME}/*"],
        ))
        role.add_to_policy(iam.PolicyStatement(
            sid="KmsViaSsmOnly",
            actions=["kms:Decrypt", "kms:GenerateDataKey"],
            resources=["*"],
            conditions={"StringEquals": {"kms:ViaService": f"ssm.{region}.amazonaws.com"}},
        ))
        role.add_to_policy(iam.PolicyStatement(
            sid="Ec2InstanceVolumeMutations",
            actions=[
                "ec2:StopInstances", "ec2:StartInstances", "ec2:RebootInstances",
                "ec2:CreateTags", "ec2:DeleteTags",
                "ec2:AttachVolume", "ec2:DetachVolume",
            ],
            resources=[
                f"arn:aws:ec2:{region}:{self.account}:instance/*",
                f"arn:aws:ec2:{region}:{self.account}:volume/*",
            ],
        ))
        role.add_to_policy(iam.PolicyStatement(
            sid="AsgActions",
            actions=[
                "autoscaling:SetInstanceProtection",
                "autoscaling:CompleteLifecycleAction",
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
            ],
            resources=["*"],  # ASG ARN is created after this role (circular); Describe needs *
        ))
        role.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        sg = ec2.SecurityGroup(self, "RocksDbSG",
            vpc=vpc,
            description="RocksDB security group",
            allow_all_outbound=True,
        )

        alb_sg = ec2.SecurityGroup(self, "AlbSG",
            vpc=vpc,
            description="ALB security group for RocksDB read traffic",
            allow_all_outbound=True,
        )
        alb_sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(80), "ALB HTTP")
        alb_sg.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # REST API (8080) reachable ONLY from the ALB — never directly from the internet.
        sg.add_ingress_rule(alb_sg, ec2.Port.tcp(8080), "RocksDB REST from ALB only")
        # Cluster coordination traffic restricted to fellow cluster members (self SG),
        # instead of the whole VPC CIDR.
        sg.add_ingress_rule(sg, ec2.Port.all_traffic(), "Cluster internal (self SG)")
        # SSH is closed to the internet by default — use SSM Session Manager for node
        # access. For break-glass SSH, pass context `admin_ssh_cidr`
        # (e.g. `cdk deploy -c admin_ssh_cidr=1.2.3.4/32`).
        admin_ssh_cidr = self.node.try_get_context("admin_ssh_cidr")
        if admin_ssh_cidr:
            sg.add_ingress_rule(ec2.Peer.ipv4(admin_ssh_cidr), ec2.Port.tcp(22), "SSH (admin CIDR)")
        sg.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # io2 Block Express Multi-Attach EBS — 256,000 IOPS (max, requires service limit increase)
        # Block Express requires >= 1,000 GiB to unlock 256,000 IOPS maximum
        data_volume = ec2.CfnVolume(self, "RocksDbDataVolume",
            availability_zone=az,
            volume_type="io2",
            size=1000,
            iops=256000,
            multi_attach_enabled=True,
            # Encryption at rest (KMS). Uses the account default EBS key. NOTE: a
            # volume cannot be encrypted in place — enabling this on an existing
            # unencrypted volume forces CloudFormation to REPLACE it (data loss),
            # so apply on a fresh deploy.
            encrypted=True,
            tags=[{"key": "Name", "value": "rocksdb-data"}],
        )
        data_volume.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # Store volume ID in SSM so UserData can self-attach
        vol_id_param = ssm.StringParameter(self, "VolumeIdParam",
            parameter_name=f"/{CLUSTER_NAME}/volume-id",
            string_value=data_volume.ref,
        )
        vol_id_param.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # Unified UserData — handles both writer and reader roles
        userdata = ec2.UserData.for_linux()
        userdata.add_commands(
            "#!/bin/bash",
            "set -euo pipefail",
            "exec > /var/log/rocksdb-userdata.log 2>&1",
            f"REGION={region}",
            f"CLUSTER_NAME={CLUSTER_NAME}",
            "AWS=/snap/bin/aws",
            "",
            "# Wait for snap AWS CLI to be ready",
            "for _i in $(seq 1 60); do $AWS --version >/dev/null 2>&1 && break; sleep 5; done",
            "",
            "# Wait for IAM credentials to be available via IMDS",
            "for _i in $(seq 1 60); do $AWS sts get-caller-identity --region $REGION >/dev/null 2>&1 && break; sleep 5; done",
            "",
            "# Get instance metadata",
            'TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")',
            'INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)',
            'AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)',
            "",
            "# Common setup",
            "mkdir -p /etc/rocksdb /etc/corosync /etc/pacemaker",
            "# Cluster 'hacluster' password: stored once in SSM (SecureString) and shared by",
            "# all nodes so pcs host auth works fleet-wide. The first node to boot creates it;",
            "# every other node reads it. (Replaces a previously hardcoded password.)",
            'HACLUSTER_PW=""',
            "for _p in $(seq 1 30); do",
            '  HACLUSTER_PW=$($AWS ssm get-parameter --name /${CLUSTER_NAME}/hacluster-password --with-decryption --query "Parameter.Value" --output text --region $REGION 2>/dev/null || echo "")',
            '  { [ -n "$HACLUSTER_PW" ] && [ "$HACLUSTER_PW" != "None" ]; } && break',
            "  GEN=$(openssl rand -hex 16)",
            '  $AWS ssm put-parameter --name /${CLUSTER_NAME}/hacluster-password --type SecureString --value "$GEN" --region $REGION >/dev/null 2>&1 && HACLUSTER_PW="$GEN" && break',
            "  sleep 5",
            "done",
            'echo "hacluster:${HACLUSTER_PW}" | chpasswd',
            "modprobe dlm || true",
            "modprobe gfs2 || true",
            "",
            "# Admin token: shared secret gating all /admin/* REST endpoints. The first",
            "# node to boot generates it in SSM (SecureString); every other node fetches it.",
            'ADMIN_TOKEN=""',
            "for _p in $(seq 1 30); do",
            '  ADMIN_TOKEN=$($AWS ssm get-parameter --name /${CLUSTER_NAME}/admin-token --with-decryption --query "Parameter.Value" --output text --region $REGION 2>/dev/null || echo "")',
            '  { [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "None" ]; } && break',
            "  GEN=$(openssl rand -hex 32)",
            '  $AWS ssm put-parameter --name /${CLUSTER_NAME}/admin-token --type SecureString --value "$GEN" --region $REGION >/dev/null 2>&1 && ADMIN_TOKEN="$GEN" && break',
            "  sleep 5",
            "done",
            "",
            "# Self-attach the EBS volume",
            'VOL_ID=$($AWS ssm get-parameter --name /${CLUSTER_NAME}/volume-id --query "Parameter.Value" --output text --region $REGION)',
            "echo \"Attaching volume ${VOL_ID}...\"",
            "VOL_ID_NODASH=$(echo $VOL_ID | tr -d '-')",
            "DEV_PATH=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_ID_NODASH}",
            "# Random delay 0-30s to spread concurrent attach attempts across 16 instances",
            "sleep $((RANDOM % 30))",
            "for _a in $(seq 1 30); do",
            "  $AWS ec2 attach-volume --volume-id $VOL_ID --instance-id $INSTANCE_ID --device /dev/sdf --region $REGION 2>/dev/null && break",
            "  echo \"  attach attempt ${_a} failed, retrying in 10s...\"",
            "  sleep 10",
            "done",
            "echo 'Waiting for device to appear...'",
            "for _w in $(seq 1 30); do [ -e $DEV_PATH ] && break; sleep 2; done",
            "[ -e $DEV_PATH ] && echo \"Device ready: $DEV_PATH\" || echo 'WARNING: device not found after 60s'",
            "",
            "# Check if we are the first node (writer) or a subsequent node (reader)",
            '# If SSM has auth keys, a cluster already exists — check if writer is alive',
            'AUTH_KEY=$($AWS ssm get-parameter --name /${CLUSTER_NAME}/corosync-authkey --with-decryption --query "Parameter.Value" --output text --region $REGION 2>/dev/null || echo "")',
            "",
            "# If auth keys exist, check if the old writer is still running",
            'BECOME_WRITER=false',
            'if [ -z "$AUTH_KEY" ]; then',
            '    BECOME_WRITER=true',
            "else",
            '    OLD_WRITER=$($AWS ssm get-parameter --name /${CLUSTER_NAME}/writer-instance-id --query "Parameter.Value" --output text --region $REGION 2>/dev/null || echo "")',
            '    # Check for a running writer by tag (covers case where SSM writer-instance-id is missing)',
            '    RUNNING_WRITER=$($AWS ec2 describe-instances --filters "Name=tag:Name,Values=RocksDB-Writer" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $REGION 2>/dev/null || echo "")',
            '    if [ -z "$OLD_WRITER" ] || [ "$OLD_WRITER" = "None" ]; then',
            '        # No writer-instance-id in SSM — become writer if no other writer is running',
            '        if [ -z "$RUNNING_WRITER" ] || [ "$RUNNING_WRITER" = "None" ]; then',
            '            echo "==> No writer-instance-id in SSM and no running writer found — becoming writer"',
            '            BECOME_WRITER=true',
            '        else',
            '            echo "==> No writer-instance-id in SSM but $RUNNING_WRITER is already writer — becoming reader"',
            '        fi',
            '    elif [ -n "$OLD_WRITER" ] && [ "$OLD_WRITER" != "None" ]; then',
            '        OLD_STATE=$($AWS ec2 describe-instances --instance-ids $OLD_WRITER --region $REGION --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "terminated")',
            '        if [ "$OLD_STATE" != "running" ]; then',
            '            if [ -z "$RUNNING_WRITER" ] || [ "$RUNNING_WRITER" = "None" ]; then',
            '                echo "==> Old writer $OLD_WRITER is $OLD_STATE and no other writer found — taking over as writer"',
            '                BECOME_WRITER=true',
            '            else',
            '                echo "==> Old writer $OLD_WRITER is $OLD_STATE but $RUNNING_WRITER is already writer — becoming reader"',
            '            fi',
            "        fi",
            "    fi",
            "fi",
            "",
            'if [ "$BECOME_WRITER" = "true" ]; then',
            "    echo '==> First node — becoming writer'",
            "    printf 'DB_PATH=/data/rocksdb/db\\nMODE=readwrite\\nPORT=8080\\n' > /etc/rocksdb/service.env",
            '    printf "ADMIN_TOKEN=%s\\n" "$ADMIN_TOKEN" >> /etc/rocksdb/service.env',
            "    printf \"CLUSTER_NAME=${CLUSTER_NAME}\\nREGION=${REGION}\\n\" > /etc/rocksdb/cluster.env",
            "    systemctl start pcsd",
            "    systemctl enable pcsd",
            "",
            "    # Tag self as writer",
            "    $AWS ec2 create-tags --region $REGION --resources $INSTANCE_ID --tags Key=Name,Value=RocksDB-Writer Key=rocksdb-role,Value=writer",
            "",
            "    # Set scale-in protection",
            '    ASG_NAME=$($AWS autoscaling describe-auto-scaling-instances --instance-ids $INSTANCE_ID --region $REGION --query "AutoScalingInstances[0].AutoScalingGroupName" --output text 2>/dev/null || echo "")',
            '    if [ -n "$ASG_NAME" ] && [ "$ASG_NAME" != "None" ]; then',
            "        $AWS autoscaling set-instance-protection --instance-ids $INSTANCE_ID --auto-scaling-group-name $ASG_NAME --protected-from-scale-in --region $REGION || true",
            "    fi",
            "",
            "    # Store writer instance ID in SSM",
            "    $AWS ssm put-parameter --name /${CLUSTER_NAME}/writer-instance-id --type String --value $INSTANCE_ID --overwrite --region $REGION || true",
            "",
            "    # Wait for volume device to appear",
            "    for i in $(seq 1 30); do ls /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_* 2>/dev/null && break; sleep 2; done",
            "",
            "    # Auto-setup cluster (single node)",
            "    PRIV_IP=$(hostname -I | awk '{print $1}')",
            "    echo \"==> Setting up single-node cluster as ${PRIV_IP}...\"",
            "    sudo pcs host auth ${PRIV_IP} -u hacluster -p \"${HACLUSTER_PW}\"",
            "    sudo pcs cluster setup ${CLUSTER_NAME} ${PRIV_IP} --force",
            "    # Enable Last Man Standing by editing corosync.conf BEFORE starting",
            "    # corosync — LMS only ENGAGES on a fresh start (a reload just loads the",
            "    # value). LMS dynamically lowers expected_votes to the live members on",
            "    # scale-down, so leftover ghost entries in corosync.conf can't inflate the",
            "    # quorum requirement and freeze DLM/GFS2 (kern_stop). A direct conf edit is",
            "    # deterministic and survives later pcs config updates (pcs quorum update",
            "    # proved unreliable here).",
            "    sudo sed -i '/provider: corosync_votequorum/a\\        last_man_standing: 1\\n        last_man_standing_window: 10000' /etc/corosync/corosync.conf",
            "    sudo pcs cluster start --all",
            "    sudo pcs cluster enable --all",
            "    sleep 10",
            "    sudo pcs property set stonith-enabled=true",
            "    sudo pcs property set no-quorum-policy=freeze",
            "    # token=30000ms: at 16 nodes corosync's effective token is base +",
            "    # (nodes-2)*~650ms (~39s here). 10s base caused TOTEM token loss/ring",
            "    # churn during reader catch-up at scale, hanging corosync reloads and",
            "    # slowing scale-up. 30s base keeps the ring stable; fencing still handles",
            "    # truly-dead nodes so slower failure detection is acceptable.",
            "    sudo pcs cluster config update totem token=30000 2>/dev/null || true",
            "",
            "    # Fencing",
            "    sudo pcs stonith create clusterfence fence_aws region=${REGION} pcmk_host_map=\"${PRIV_IP}:${INSTANCE_ID}\" power_timeout=240 pcmk_reboot_timeout=480 pcmk_reboot_retries=4",
            "",
            "    # DLM",
            "    sudo pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true",
            "    sleep 15",
            "",
            "    # GFS2 — find the volume device",
            "    VOL_SERIAL=$(echo $VOL_ID | sed 's/-//')",
            "    DEVICE_BY_ID=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_SERIAL}",
            "    HAS_GFS2=$(sudo blkid ${DEVICE_BY_ID} 2>/dev/null | grep -c gfs2 || echo 0)",
            "    if [ \"${HAS_GFS2}\" -gt 0 ]; then",
            "        echo '  GFS2 already exists'",
            "    else",
            "        echo '  Formatting GFS2...'",
            "        echo y | sudo mkfs.gfs2 -j16 -p lock_dlm -t ${CLUSTER_NAME}:rocksdb -O ${DEVICE_BY_ID}",
            "    fi",
            "    sudo pcs resource create gfs2fs ocf:heartbeat:Filesystem device=${DEVICE_BY_ID} directory=/data/rocksdb fstype=gfs2 options=noatime op monitor interval=10s on-fail=fence clone interleave=true",
            "    sudo pcs constraint order start dlm-clone then gfs2fs-clone",
            "    sudo pcs resource update gfs2fs op start timeout=300s op stop timeout=300s op monitor timeout=300s interval=30s",
            "    sleep 20",
            "",
            "    # DB directory + ID counter (only init counter if not present)",
            "    sudo mkdir -p /data/rocksdb/db",
            "    sudo chmod 777 /data/rocksdb/db",
            "    [ -f /data/rocksdb/.next_nodeid ] || echo 2 > /data/rocksdb/.next_nodeid",
            "    chmod 666 /data/rocksdb/.next_nodeid",
            "",
            "    # Store auth keys in SSM",
            "    $AWS ssm put-parameter --name /${CLUSTER_NAME}/corosync-authkey --type SecureString --value \"$(sudo base64 -w0 /etc/corosync/authkey)\" --overwrite --region $REGION || true",
            "    $AWS ssm put-parameter --name /${CLUSTER_NAME}/pacemaker-authkey --type SecureString --value \"$(sudo base64 -w0 /etc/pacemaker/authkey)\" --overwrite --region $REGION || true",
            "",
            "    # Start services",
            "    sudo systemctl start cluster-watcher.service",
            "    sudo systemctl enable cluster-watcher.service",
            "    sudo systemctl restart rocksdb.service",
            "    echo '==> Writer setup complete.'",
            "",
            "else",
            "    echo '==> Joining existing cluster as reader'",
            "    printf 'DB_PATH=/data/rocksdb/db\\nMODE=readonly\\nPORT=8080\\n' > /etc/rocksdb/service.env",
            '    printf "ADMIN_TOKEN=%s\\n" "$ADMIN_TOKEN" >> /etc/rocksdb/service.env',
            "",
            "    # Clean stale cluster config — full wipe",
            "    systemctl stop pacemaker corosync pcsd 2>/dev/null || true",
            "    systemctl disable pacemaker corosync 2>/dev/null || true",
            "    sleep 2",
            "    rm -f /etc/corosync/corosync.conf",
            "    rm -rf /var/lib/pacemaker/cib/",
            "    mkdir -p /var/lib/pacemaker/cib",
            "    rm -rf /var/lib/corosync/",
            "    mkdir -p /var/lib/corosync",
            "    rm -rf /var/lib/pcsd/",
            "    mkdir -p /var/lib/pcsd",
            "",
            "    # Fetch auth keys from SSM",
            '    echo "$AUTH_KEY" | base64 -d > /etc/corosync/authkey',
            "    $AWS ssm get-parameter --name /${CLUSTER_NAME}/pacemaker-authkey --with-decryption --query 'Parameter.Value' --output text --region $REGION | base64 -d > /etc/pacemaker/authkey",
            "    chmod 400 /etc/corosync/authkey /etc/pacemaker/authkey",
            "",
            "    # Tag for watcher join FIRST — use separate calls to avoid multi-tag parsing issues",
            "    for _t in $(seq 1 60); do $AWS ec2 create-tags --region $REGION --resources $INSTANCE_ID --tags Key=Name,Value=RocksDB-Reader 2>/dev/null && break; sleep 5; done",
            "    for _t in $(seq 1 60); do $AWS ec2 create-tags --region $REGION --resources $INSTANCE_ID --tags Key=rocksdb-role,Value=reader 2>/dev/null && break; sleep 5; done",
            "    for _t in $(seq 1 60); do $AWS ec2 create-tags --region $REGION --resources $INSTANCE_ID --tags Key=rocksdb-join,Value=${CLUSTER_NAME} 2>/dev/null && break; sleep 5; done",
            "",
            "    # Start pcsd",
            "    systemctl start pcsd",
            "    systemctl enable pcsd",
            "",
            "    # Start rocksdb service (will wait for GFS2 mount)",
            "    systemctl start rocksdb.service || true",
            "fi",
        )

        # Launch Template
        launch_template = ec2.LaunchTemplate(self, "RocksDbLT",
            instance_type=ec2.InstanceType("m5d.2xlarge"),
            machine_image=machine_image,
            key_pair=key_pair,
            security_group=sg,
            role=role,
            user_data=userdata,
            # Harden IMDS: require IMDSv2 and prevent the token from being relayed
            # beyond the instance (mitigates SSRF-based credential theft).
            require_imdsv2=True,
            http_put_response_hop_limit=1,
            block_devices=[
                ec2.BlockDevice(
                    device_name="/dev/xvda",
                    volume=ec2.BlockDeviceVolume.ebs(
                        30,
                        volume_type=ec2.EbsDeviceVolumeType.GP3,
                        delete_on_termination=True,
                    ),
                ),
            ],
            associate_public_ip_address=True,
        )
        launch_template.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # ASG using Launch Template — placed in the dedicated VPC public subnet
        asg = autoscaling.AutoScalingGroup(self, "RocksDbASG",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(
                availability_zones=[az],
                subnet_type=ec2.SubnetType.PUBLIC,
            ),
            launch_template=launch_template,
            min_capacity=1,
            max_capacity=16,
            desired_capacity=1,
            new_instances_protected_from_scale_in=False,
        )
        asg.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # No lifecycle hook — nodes terminate immediately. GFS2 journal recovery
        # on surviving nodes handles data consistency. DLM needs fencing confirmation
        # which requires the node to be truly dead, not in Terminating:Wait.
        # Nodes terminate immediately; GFS2 journal recovery handles data consistency.

        # ALB for read traffic — sits in front of all ASG instances (writer + readers all serve reads)
        alb = elbv2.ApplicationLoadBalancer(self, "ReadAlb",
            vpc=vpc,
            internet_facing=True,
            security_group=alb_sg,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
        )
        alb.apply_removal_policy(cdk.RemovalPolicy.DESTROY)

        # ALB access logs → S3 (audit trail of every request through the LB)
        alb_log_bucket = s3.Bucket(self, "AlbAccessLogs",
            removal_policy=cdk.RemovalPolicy.DESTROY,
            auto_delete_objects=True,
            encryption=s3.BucketEncryption.S3_MANAGED,
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            enforce_ssl=True,
        )
        alb.log_access_logs(alb_log_bucket)

        tg = elbv2.ApplicationTargetGroup(self, "ReadTG",
            vpc=vpc,
            port=8080,
            protocol=elbv2.ApplicationProtocol.HTTP,
            target_type=elbv2.TargetType.INSTANCE,
            # Read replicas are stateless and serve sub-second GETs, so there are no
            # long-lived connections to drain on scale-in. The AWS default (300s) just
            # makes every scale-down wait ~5 min before terminating readers; 30s is
            # ample for in-flight reads to finish.
            deregistration_delay=cdk.Duration.seconds(30),
            health_check=elbv2.HealthCheck(
                path="/health",
                port="8080",
                healthy_http_codes="200",
                interval=cdk.Duration.seconds(15),
                timeout=cdk.Duration.seconds(5),
                healthy_threshold_count=2,
                unhealthy_threshold_count=3,
            ),
        )

        listener = alb.add_listener("ReadListener",
            port=80,
            protocol=elbv2.ApplicationProtocol.HTTP,
            default_target_groups=[tg],
        )

        # Defense in depth: never serve /admin/* through the public load balancer.
        # Admin actions must be invoked on-box (via SSM) where the token is enforced.
        listener.add_action("BlockAdminViaAlb",
            priority=1,
            conditions=[elbv2.ListenerCondition.path_patterns(["/admin/*"])],
            action=elbv2.ListenerAction.fixed_response(403,
                content_type="application/json",
                message_body='{"error":"forbidden"}',
            ),
        )

        # The public data plane is read-only. Mutating/writer-only endpoints must
        # never be reachable via the (unauthenticated) ALB: the LB load-balances
        # across all nodes, so a write could land on the writer — and on a single
        # node cluster the writer is the only target, making it a 100% reachable
        # unauthenticated write path from the internet. Writes/deletes/flush are
        # driven on-box against the writer via SSM instead. GET /get and /scan
        # (reads) and /health are unaffected.
        listener.add_action("BlockWritesViaAlb",
            priority=2,
            conditions=[elbv2.ListenerCondition.path_patterns(
                ["/put", "/batch-put", "/delete", "/flush"])],
            action=elbv2.ListenerAction.fixed_response(403,
                content_type="application/json",
                message_body='{"error":"forbidden"}',
            ),
        )

        asg.attach_to_application_target_group(tg)

        # NOTE: No AWS WAF on the ALB. A rate-based WebACL was evaluated but removed:
        # this is a demo whose load/stress tests deliberately flood the ALB from a
        # few loader IPs (each well above any sane per-IP rate), so a rate-based rule
        # blocks the stress test itself. The DoS risk for the unauthenticated data
        # plane is accepted for the demo and partly offset by the bounded /scan and
        # the in-VPC, ALB-only network posture. Re-add a WAF (or per-IP allow-list)
        # before any non-demo/production use. See threat model T6/T11.

        cdk.CfnOutput(self, "ASGName",
            value=asg.auto_scaling_group_name,
            description="Auto Scaling Group name",
        )
        cdk.CfnOutput(self, "DataVolumeId",
            value=data_volume.ref,
            description="io2 Multi-Attach data volume ID",
        )
        cdk.CfnOutput(self, "ReadAlbDns",
            value=alb.load_balancer_dns_name,
            description="ALB DNS for read traffic (port 80 -> :8080)",
        )
        cdk.CfnOutput(self, "VpcId",
            value=vpc.vpc_id,
            description="VPC ID for the RocksDB cluster",
        )
