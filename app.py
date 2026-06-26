import os
import aws_cdk as cdk
from rocksdb_stack import RocksDbStack

app = cdk.App()
RocksDbStack(app, "RocksDbStack",
    env=cdk.Environment(
        account=os.environ.get("CDK_DEFAULT_ACCOUNT"),
        region=os.environ.get("CDK_DEFAULT_REGION", "us-east-1"),
    ),
)
app.synth()
