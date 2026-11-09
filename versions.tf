terraform {
  required_version = ">= 1.9.0"

  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.3"
    }
    # Not yet published to the registry - requires dev_overrides pointing
    # at a local build until a release exists. See
    # https://github.com/rafalmasiarek/terraform-provider-netutils.
    netutils = {
      source = "rafalmasiarek/netutils"
    }
  }
}
