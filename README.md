# terraform-null-cloudinit

Renders a multipart MIME cloud-init payload (via the `hashicorp/cloudinit` provider) for a `user_data`-style argument - AWS EC2, GCP, Azure, Hetzner, or anywhere else cloud-init runs. Typed helper variables map to native cloud-init cloud-config modules (packages, users, files, mounts, ssh, ansible, ...); `cloud_config` is the escape hatch for anything not covered. The `null` in the name follows the same convention as `terraform-null-tagger`/cloudposse's `terraform-null-label` - this module creates no real infrastructure, only renders a string. It never creates a compute instance, IAM role/service account, or storage bucket on any provider.

## Naming convention

Each helper variable name matches cloud-init's own module name where one exists (`packages`, `users`, `mounts`, `ntp`, `ansible_pull`, ...), kept as close to the native cloud-config key as the Terraform type system allows. Where cloud-init nests several keys under one conceptual module (e.g. `package_update`/`package_upgrade` under package handling), this module groups them into one object variable (`packages = { install = [...], update = true }`) rather than exposing each cloud-config key as a flat Terraform variable.

## Basic usage (cloud_config + shell_scripts)

```hcl
module "cloudinit" {
  source = "git::https://github.com/rafalmasiarek/terraform-null-cloudinit.git?ref=v0.1.0"

  cloud_config = {
    final_message = "cloud-init finished"
  }

  shell_scripts = [
    "#!/bin/bash\necho hello from shell_scripts\n"
  ]
}
```

## Native helpers

```hcl
module "cloudinit" {
  source = "..."

  hostname = "app-node"
  timezone = "UTC"

  packages = {
    install = ["curl", "jq", "unzip"]
    update  = true
  }

  users = [
    {
      name                = "deploy"
      groups              = ["wheel"]
      shell               = "/bin/bash"
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      ssh_authorized_keys = ["ssh-ed25519 AAAA..."]
    }
  ]

  files = {
    "/etc/example/config.yaml" = {
      content     = yamlencode({ key = "value" })
      permissions = "0640"
    }
  }

  mounts = [
    ["LABEL=data", "/mnt/data", "ext4", "defaults,nofail", "0", "2"]
  ]
}
```

## Local script via `file()`/`templatefile()`

```hcl
module "cloudinit" {
  source = "..."

  shell_scripts = [
    file("${path.module}/scripts/bootstrap.sh"),
    templatefile("${path.module}/scripts/configure.sh.tftpl", {
      environment = "prod"
    }),
  ]
}
```

## Frequency-scoped scripts

```hcl
module "cloudinit" {
  source = "..."

  scripts = {
    boothook     = ["#!/bin/bash\necho earliest, every boot, as root\n"]
    per_boot     = [file("${path.module}/scripts/check-mounts.sh")]
    per_instance = [file("${path.module}/scripts/bootstrap-once-per-instance.sh")]
    per_once     = []
  }
}
```

`boothook` runs earliest of all, every boot, as root. `per_boot` runs every boot. `per_instance` runs once per new instance id (new AMI/launch = new id). `per_once` runs exactly once, ever, regardless of instance id changes. Plain `shell_scripts` is cloud-init's original/default script type, also once per instance.

## S3 script retrieval + execution (IAM instance role, no static credentials)

```hcl
module "cloudinit" {
  source = "..."

  artifacts = [
    {
      source      = "s3://company-bootstrap/scripts/setup.sh"
      destination = "/opt/bootstrap/setup.sh"
      permissions = "0750"
      sha256      = "..." # optional integrity check
    }
  ]

  execution_steps = [
    { command = "/opt/bootstrap/setup.sh" }
  ]
}

# Attach this to whatever IAM role the EC2 instance / launch template uses -
# this module only computes the policy, it never creates or attaches a role.
resource "aws_iam_role_policy" "bootstrap_s3_read" {
  name   = "bootstrap-s3-read"
  role   = aws_iam_role.instance.id
  policy = module.cloudinit.required_permissions.aws.policy_json
}
```

The fetch happens on the compute at boot, via the matching CLI using its own attached identity - never through a Terraform data source at plan time (see "Why not `data.aws_s3_object`" below). The source scheme picks the mechanism:

| Scheme | CLI used | Identity | Install |
|---|---|---|---|
| `s3://bucket/key` | `aws s3 cp` | AWS IAM instance role (IMDSv2) | `awscli` via `dnf`/`yum`/`apt-get` if missing |
| `gs://bucket/object` | `gcloud storage cp` | GCP attached service account | must already be on the image - no reliable one-line install |
| `azblob://account/container/blob` | `az storage blob download --auth-mode login` | Azure Managed Identity | must already be on the image - no reliable one-line install |
| `https://...` | `curl` | none needed | always available |

`endpoint_url` on an `s3://` entry also covers any S3-compatible object storage - Hetzner Object Storage, MinIO, etc:

```hcl
artifacts = [
  {
    source       = "s3://my-hetzner-bucket/scripts/setup.sh"
    destination  = "/opt/bootstrap/setup.sh"
    endpoint_url = "https://fsn1.your-objectstorage.com"
  }
]
```

## S3 Ansible playbook/project retrieval + local run

```hcl
module "cloudinit" {
  source = "..."

  artifacts = [
    {
      source      = "s3://company-bootstrap/ansible/app-bootstrap.tar.gz"
      destination = "/opt/bootstrap/app-bootstrap.tar.gz"
      extract     = true
      extract_to  = "/opt/bootstrap/ansible"
    }
  ]

  ansible_playbooks = [
    {
      path       = "/opt/bootstrap/ansible/site.yml"
      connection = "local"
      extra_vars = { environment = "prod" }
    }
  ]
}
```

A standalone `site.yml` isn't enough for a playbook that references external roles/templates - ship the whole project as one `.tar.gz` and extract it, as above. `ansible_playbooks` always runs via a plain `ansible-playbook` shell invocation, installing `ansible-core` first if missing - deliberately not cloud-init's native `ansible.setup_controller` module (see "Two Ansible paths" below for why).

## Local Ansible playbook from this repo

```hcl
module "cloudinit" {
  source = "..."

  files = {
    "/opt/bootstrap/ansible/site.yml" = {
      content = file("${path.module}/ansible/site.yml")
    }
  }

  ansible_playbooks = [
    { path = "/opt/bootstrap/ansible/site.yml", connection = "local" }
  ]
}
```

## Native `ansible-pull` from Git (separate from the S3 path)

```hcl
module "cloudinit" {
  source = "..."

  ansible_pull = [
    {
      url            = "https://github.com/example/playbooks.git"
      playbook_names = ["site.yml"]
    }
  ]
}
```

cloud-init's native `ansible` module only supports pulling from a git-cloneable remote URL this way - it has no concept of a local or S3-sourced playbook, hence the separate `ansible_playbooks` variable above for that case.

## HTTPS artifact with checksum and permissions

```hcl
module "cloudinit" {
  source = "..."

  artifacts = [
    {
      source      = "https://example.com/tools/agent.tar.gz"
      destination = "/opt/agent/agent.tar.gz"
      sha256      = "3b6f...e91a"
      permissions = "0644"
      extract     = true
    }
  ]
}
```

HTTPS downloads use plain `curl -fsSL`, no AWS CLI involved. Prefer HTTPS + `sha256` over an unauthenticated HTTP URL. A pre-signed S3 URL isn't recommended for anything baked into a long-lived launch template - it expires; use `s3://` with the instance's IAM role instead.

## Advanced escape hatches

**Raw `cloud_config`** - anything a typed helper doesn't cover:
```hcl
cloud_config = {
  snap     = { commands = [["install", "--classic", "kubectl"]] }
  wireguard = { interfaces = [...] }
}
```
A top-level key set both here and by a typed helper is a hard error at plan time - pick one.

**Raw `cloudinit_parts`** - arbitrary MIME parts, including `#include` URL lists, part-handlers, and Jinja-templated parts:
```hcl
cloudinit_parts = [
  { content_type = "text/x-include-url", content = "https://example.com/extra-cloud-config.txt" },
  { content_type = "text/part-handler", content = file("${path.module}/handlers/my_handler.py") },
  { content_type = "text/cloud-config", content = "## template: jinja\n#cloud-config\nruncmd: [\"echo Running on {{ v1.cloud_name }}\"]\n" },
]
```
`#include`/`text/x-include-url` only documents HTTPS URLs - no authenticated/non-HTTPS scheme is confirmed supported. Part-handlers need a Python module with `list_types()` + `handle_part(...)` (v1) or additionally `handler_version = 2` and a `frequency` parameter (v2). A Jinja part's `## template: jinja` line must be the literal first line, with the part's own header (`#cloud-config`, `#!`, ...) immediately below it.

**Merge behavior**: this module renders exactly one `text/cloud-config` part (the merged result of every typed helper plus `cloud_config`), so cloud-init's cross-part merge rules don't come into play for that part. If you add a *second* `text/cloud-config` part yourself via `cloudinit_parts`, cloud-init's default merge is `list()+dict()+str()` (dict keys: later part wins unless `merge_type`/`Merge-Type` says otherwise) - set `merge_type` on that part if you need different behavior.

## Why not `data "aws_s3_object"`?

A simpler-looking alternative is fetching the script via Terraform itself and setting it as `user_data` directly:

```hcl
data "aws_s3_object" "bootstrap_script" {
  bucket = "company-bootstrap"
  key    = "scripts/setup.sh"
}
# user_data = data.aws_s3_object.bootstrap_script.body
```

This works for a small, rarely-changing, non-sensitive script, but has real costs this module avoids: it requires the **Terraform runner's** credentials to have `s3:GetObject` (not the EC2 instance's own narrow role); the content is stored in Terraform state in plaintext; and because launch templates are versioned, any change to the S3 object requires a fresh `terraform apply` to reach new instances. Boot-time fetch (what `artifacts` does) decouples content updates from Terraform applies entirely, keeps big/sensitive content out of state, and is the AWS-documented workaround for content too large for the 16KB `user_data` limit. Nothing stops you from using `data "aws_s3_object"` yourself outside this module for the simple static-script case - just pass its `.body` into `shell_scripts` or `files`.

## Two Ansible paths, and why they're separate

- `ansible_pull` → cloud-init's **native** `ansible` module. Git-only (`ansible-pull` clones a repo and runs it) - confirmed from cloud-init's own docs, which describe the URL as a remote git repository, not a local path.
- `ansible_playbooks` → a **generated shell script**, not cloud-init's native `ansible.setup_controller.run_ansible` (which *does* support running an already-present local playbook). This module doesn't use that native path because it can't guarantee `setup_controller` runs *after* an `artifacts`/`runcmd`-based S3 download within the same boot - cloud-init's own module-ordering guarantees don't cover ordering between those two independent subsystems. Keeping download + install + run in one script avoids relying on unconfirmed cross-module ordering.

## Distro/AMI caveats

- **AWS CLI**: assumed present on Amazon Linux 2023; installed via `dnf`/`yum`/`apt-get` otherwise if `artifacts` has any `s3://` source. No internet access from the instance means this step fails - plan accordingly for fully air-gapped subnets.
- **ansible-core**: not assumed present anywhere; installed automatically before `ansible_playbooks` runs unless `ansible_core_install = false`.
- **apt**/`yum_repos` helpers are distro-scoped (Debian/Ubuntu vs RHEL family including Amazon Linux) - setting the wrong one for your AMI is simply a no-op, not an error.
- **`disk_setup`/`fs_setup` with `overwrite = true`** is destructive - cloud-init's own docs call this out explicitly. Off by default.
- **`mounts`**: use `UUID=...`/`LABEL=...`, not a raw `/dev/xvd*` path - device naming can differ between the guest OS and the actual EBS attachment on Nitro instances.
- **EC2 `user_data` limit**: 16384 bytes, raw/decoded, post-gzip if `gzip = true`. A `postcondition` on the rendered payload fails `plan` with a clear message if you're over it, rather than failing at `apply` with a cryptic AWS API error.

## Consuming the output

```hcl
resource "aws_launch_template" "this" {
  # ...
  user_data = module.cloudinit.rendered
}
```

`rendered` is already base64-encoded (the provider's own `base64_encode = true`) - pass it straight into `user_data_base64`-style arguments; don't `base64encode()` it again. This module doesn't create the launch template, ASG, or instance itself - see `terraform-aws-ec2-autoscale-group` for that, which accepts this module's `cloudinit_parts`-shaped list directly and renders the same way internally.

## Inputs

See `variables.tf` - organized by section (frequency-scoped scripts, packages, users/groups, files, commands, hostname/timezone, mounts/disks, ssh/certs, ntp, apt, yum, ansible, power_state/phone_home/rsyslog, artifacts, ansible_playbooks/execution_steps). Every helper defaults to `null`/`[]`/`{}` (omitted from the rendered config) when unset.

## Outputs

| Name | Description |
|---|---|
| `rendered` | Base64-encoded multipart MIME payload, or `null` if nothing was configured. |
| `raw_bytes` | Decoded (post-gzip) size - compare against your platform's limit. |
| `has_user_data` | Whether anything was actually generated. |
| `content_types` | `content_type` of every part, in order - for debugging without decoding. |
| `generated_cloud_config` | The merged cloud-config object before rendering (sensitive - may contain whatever you put in `files`/`users`/`cloud_config`). |
| `required_permissions` | `{ aws.policy_json, gcp.{role,objects}, azure.{role,blobs} }` - per-provider permission requirements for configured `artifacts[]`, each `null` if that scheme isn't used. This module never creates or attaches any of these. |
