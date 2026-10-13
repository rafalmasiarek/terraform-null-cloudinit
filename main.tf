locals {
  cloud_config_part = length(local.cloud_config_merged) == 0 ? [] : [{
    content_type = "text/cloud-config"
    content      = "#cloud-config\n${yamlencode(local.cloud_config_merged)}"
    filename     = null
    merge_type   = null
  }]

  boothook_parts = [
    for s in var.scripts.boothook : {
      content_type = "text/cloud-boothook"
      content      = s
      filename     = null
      merge_type   = null
    }
  ]

  per_boot_parts = [
    for s in var.scripts.per_boot : {
      content_type = "text/x-shellscript-per-boot"
      content      = s
      filename     = null
      merge_type   = null
    }
  ]

  per_instance_parts = [
    for s in var.scripts.per_instance : {
      content_type = "text/x-shellscript-per-instance"
      content      = s
      filename     = null
      merge_type   = null
    }
  ]

  per_once_parts = [
    for s in var.scripts.per_once : {
      content_type = "text/x-shellscript-per-once"
      content      = s
      filename     = null
      merge_type   = null
    }
  ]

  shell_script_parts = [
    for script in var.shell_scripts : {
      content_type = "text/x-shellscript"
      content      = script
      filename     = null
      merge_type   = null
    }
  ]

  all_parts = concat(
    local.boothook_parts,
    local.cloud_config_part,
    local.per_boot_parts,
    local.per_instance_parts,
    local.per_once_parts,
    local.shell_script_parts,
    local.bootstrap_part,
    var.cloudinit_parts,
  )
}

data "cloudinit_config" "this" {
  count = length(local.all_parts) > 0 ? 1 : 0

  base64_encode = true
  gzip          = var.gzip

  dynamic "part" {
    for_each = local.all_parts
    content {
      content_type = part.value.content_type
      content      = part.value.content
      filename     = part.value.filename
      merge_type   = part.value.merge_type
    }
  }

  lifecycle {
    postcondition {
      condition     = length(base64decode(self.rendered)) <= var.max_bytes
      error_message = "Rendered cloud-init payload is ${length(base64decode(self.rendered))} bytes, over the ${var.max_bytes}-byte limit. Set gzip = true, or trim the inputs."
    }
  }
}

locals {
  rendered  = try(data.cloudinit_config.this[0].rendered, null)
  raw_bytes = local.rendered != null ? length(base64decode(local.rendered)) : 0
}
