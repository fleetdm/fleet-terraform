module "fleet" {
  source             = "../gcp"
  billing_account_id = "018189-3756B2-E586C1"
  org_id             = "885948355217"
  dns_record_name    = "dogfoodgcp.fleetdm.com."
  dns_zone_name      = "dogfoodgcp.fleetdm.com."
}