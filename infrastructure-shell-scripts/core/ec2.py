"""
EC2 helpers — launch instances, wait for state changes, retrieve IPs.
"""
import config
from core.state import DeployState, tag_spec


def _log(msg: str) -> None:
    print(f"  [ec2] {msg}")


def launch_instance(
    ec2,
    state: DeployState,
    name: str,
    subnet_id: str,
    sg_ids: list,
    userdata: str,
    public_ip: bool = False,
    instance_type: str = None,
    key_name: str = None,
    dry_run: bool = False,
) -> str:
    """
    Launch a single EC2 instance and return its instance ID.

    public_ip : True  → NetworkInterface with AssociatePublicIpAddress=True
                False → plain SubnetId/SecurityGroupIds (private subnet)
    """
    itype = instance_type or config.DEFAULT_INSTANCE_TYPE
    prefix = "[DRY RUN] " if dry_run else ""

    _log(f"{prefix}Launching {name} ({itype}, public_ip={public_ip})…")
    if dry_run:
        mock_id = f"i-dryrun-{name.replace('-', '')}"
        _log(f"  Would launch {name} → {mock_id}")
        return mock_id

    kwargs = dict(
        ImageId=config.AMI_ID,
        InstanceType=itype,
        MinCount=1,
        MaxCount=1,
        IamInstanceProfile={"Arn": config.IAM_INSTANCE_PROFILE_ARN},
        UserData=userdata,
        BlockDeviceMappings=[{
            "DeviceName": "/dev/sda1",
            "Ebs": {
                "VolumeSize": config.DEFAULT_VOLUME_GB,
                "VolumeType": "gp3",
                "DeleteOnTermination": True,
            },
        }],
        TagSpecifications=tag_spec("instance", state.scenario, name),
    )

    if key_name:
        kwargs["KeyName"] = key_name

    if public_ip:
        # NetworkInterfaces block controls both subnet and public IP assignment
        kwargs["NetworkInterfaces"] = [{
            "AssociatePublicIpAddress": True,
            "DeviceIndex": 0,
            "SubnetId": subnet_id,
            "Groups": sg_ids,
        }]
        kwargs["TagSpecifications"] = [
            ts for ts in kwargs["TagSpecifications"]  # keep instance tags
        ]
        # Also tag the network interface
        kwargs["TagSpecifications"].append({
            "ResourceType": "network-interface",
            "Tags": [{"Key": "Name", "Value": f"{name}-eni"}],
        })
    else:
        kwargs["SubnetId"] = subnet_id
        kwargs["SecurityGroupIds"] = sg_ids

    resp = ec2.run_instances(**kwargs)
    instance_id = resp["Instances"][0]["InstanceId"]
    _log(f"  Launched {name}: {instance_id}")
    return instance_id


def wait_running(ec2, instance_id: str) -> None:
    """Block until the instance reaches the 'running' state."""
    _log(f"Waiting for {instance_id} to be running…")
    waiter = ec2.get_waiter("instance_running")
    waiter.wait(
        InstanceIds=[instance_id],
        WaiterConfig={"Delay": 15, "MaxAttempts": 40},
    )
    _log(f"  {instance_id} is running.")


def wait_terminated(ec2, instance_ids: list) -> None:
    """Block until all given instances are terminated."""
    ids = [i for i in instance_ids if i and not i.startswith("i-dryrun")]
    if not ids:
        return
    _log(f"Waiting for instances to terminate: {ids}…")
    waiter = ec2.get_waiter("instance_terminated")
    waiter.wait(
        InstanceIds=ids,
        WaiterConfig={"Delay": 15, "MaxAttempts": 60},
    )
    _log("  All instances terminated.")


def get_private_ip(ec2, instance_id: str) -> str:
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    return resp["Reservations"][0]["Instances"][0]["PrivateIpAddress"]


def get_public_ip(ec2, instance_id: str) -> str:
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    return resp["Reservations"][0]["Instances"][0].get("PublicIpAddress", "")


def terminate_instances(ec2, state: DeployState) -> None:
    """Terminate all instances recorded in state."""
    from botocore.exceptions import ClientError

    ids = [
        i for i in [
            state.instance_db,
            state.instance_backend,
            state.instance_frontend,
        ]
        if i and not i.startswith("i-dryrun")
    ]
    if not ids:
        _log("No instances to terminate.")
        return

    _log(f"Terminating instances: {ids}")
    try:
        ec2.terminate_instances(InstanceIds=ids)
    except ClientError as e:
        _log(f"WARNING: {e.response['Error']['Message']}")

    wait_terminated(ec2, ids)
