output "rendered" {
  description = "Base64-encoded multipart MIME cloud-init payload, ready for a user_data (or cloud-provider equivalent) argument. Null if there's nothing to render."
  value       = local.rendered
}

output "raw_bytes" {
  description = "Decoded (post-gzip) size in bytes - compare against your platform's user_data limit."
  value       = local.raw_bytes
}

output "has_user_data" {
  description = "Whether any part was actually generated - lets a caller skip setting user_data entirely rather than wiring in a null."
  value       = local.rendered != null
}

output "content_types" {
  description = "content_type of every part in the rendered payload, in order - useful for debugging without decoding the base64."
  value       = [for p in local.all_parts : p.content_type]
}

output "generated_cloud_config" {
  description = "The merged cloud-config object before YAML/base64 rendering - for inspection, not consumption. May contain whatever sensitive content the caller put into files/users/cloud_config."
  value       = local.cloud_config_merged
  sensitive   = true
}

output "required_permissions" {
  description = "Per-provider permission requirements for whatever artifacts[] sources are configured, keyed by provider - each null if that provider's scheme isn't used. This module never creates or attaches any of these; wire them into whatever identity the compute actually runs as (AWS IAM role, GCP service account, Azure Managed Identity)."
  value = {
    aws = {
      policy_json = local.aws_required_permissions
    }
    gcp   = local.gcp_required_permissions
    azure = local.azure_required_permissions
  }
}
