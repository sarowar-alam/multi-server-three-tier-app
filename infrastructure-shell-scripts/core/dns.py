"""
Route53 helpers — create/delete A records for each deployment scenario.

ALB scenarios   → Alias A record  (ALB DNS + ALB canonical hosted zone ID)
Public+domain   → Plain A record  (EC2 public IP, TTL=60)
"""
import config


def _log(msg: str) -> None:
    print(f"  [dns] {msg}")


def upsert_alias(r53, domain: str, alb_dns: str, alb_canonical_zone_id: str) -> None:
    """Create/update an Alias A record pointing to an ALB."""
    _log(f"Upserting Route53 alias: {domain} → {alb_dns}")
    r53.change_resource_record_sets(
        HostedZoneId=config.ROUTE53_ZONE_ID,
        ChangeBatch={
            "Comment": f"BMI deploy — alias for {domain}",
            "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": domain,
                    "Type": "A",
                    "AliasTarget": {
                        "HostedZoneId": alb_canonical_zone_id,
                        "DNSName": alb_dns,
                        "EvaluateTargetHealth": True,
                    },
                },
            }],
        },
    )
    _log(f"  Alias record upserted.")


def upsert_a_record(r53, domain: str, ip: str, ttl: int = 60) -> None:
    """Create/update a plain A record for an EC2 public IP."""
    _log(f"Upserting Route53 A record: {domain} → {ip} (TTL {ttl}s)")
    r53.change_resource_record_sets(
        HostedZoneId=config.ROUTE53_ZONE_ID,
        ChangeBatch={
            "Comment": f"BMI deploy — A record for {domain}",
            "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": domain,
                    "Type": "A",
                    "TTL": ttl,
                    "ResourceRecords": [{"Value": ip}],
                },
            }],
        },
    )
    _log(f"  A record upserted.")


def delete_record(r53, domain: str, is_alias: bool,
                  ip: str = "", alb_dns: str = "",
                  alb_canonical_zone_id: str = "") -> None:
    """Delete a Route53 record (alias or plain A)."""
    if not domain:
        return
    _log(f"Deleting Route53 record: {domain}")
    try:
        if is_alias:
            change = {
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": domain,
                    "Type": "A",
                    "AliasTarget": {
                        "HostedZoneId": alb_canonical_zone_id,
                        "DNSName": alb_dns,
                        "EvaluateTargetHealth": True,
                    },
                },
            }
        else:
            change = {
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": domain,
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": ip}],
                },
            }
        r53.change_resource_record_sets(
            HostedZoneId=config.ROUTE53_ZONE_ID,
            ChangeBatch={"Changes": [change]},
        )
        _log(f"  Record deleted.")
    except Exception as e:
        _log(f"  WARNING deleting {domain}: {e}")
