# terraform-null-cloudinit
## About

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

## systemd units

```hcl
module "cloudinit" {
  source = "..."

  systemd_units = [
    {
      name    = "secret-agent"
      enabled = true
      content = file("${path.module}/units/secret-agent.service")
      dropins = {
        "10-runtime.conf" = "[Service]\nRuntimeDirectory=secret-agent\n"
      }
    }
  ]
}
```

Unit files and drop-ins are written to `/etc/systemd/system` via `write_files` (0644, root:root, deferred); `systemctl daemon-reload` and `systemctl enable` run in `runcmd`, before `commands[]`. `enabled` requires an `[Install]` section. A path set in both `files` and `systemd_units` is a hard error.

## Runtime secrets

```hcl
module "cloudinit" {
  source = "..."

  secrets = [
    {
      name        = "db-password"
      destination = "/run/secrets/db-password"
      command     = "aws secretsmanager get-secret-value --secret-id prod/db --query SecretString --output text"
    },
    {
      name        = "tls-key"
      destination = "/etc/tls/key.pem"
      source_path = "/opt/bootstrap/tls-key.pem"
      owner       = "app:app"
    },
  ]
}
```

A generated oneshot service (name in `secrets_service`, enabled at boot) materializes each entry: `source_path` copies a file already on the instance (e.g. fetched by `artifacts`), `command` writes its stdout. Only the path/command enters user-data, never the value.

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


## Terraform Reference



### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.8.5 |
| <a name="requirement_cloudinit"></a> [cloudinit](#requirement\_cloudinit) | >= 2.3 |

### Modules

No modules.

### Resources

| Name | Type |
|------|------|
| [terraform_data.cloud_config_conflict_check](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [cloudinit_config.this](https://registry.terraform.io/providers/hashicorp/cloudinit/latest/docs/data-sources/config) | data source |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ansible_core_install"></a> [ansible\_core\_install](#input\_ansible\_core\_install) | Install ansible-core via the distro package manager before running ansible\_playbooks, if ansible-playbook isn't already on PATH. | `bool` | `true` | no |
| <a name="input_ansible_install_method"></a> [ansible\_install\_method](#input\_ansible\_install\_method) | How to install ansible-core before ansible\_pull runs - "distro" or "pip". Only applies to ansible\_pull (the native module); ansible\_playbooks manages its own install separately, see ansible\_core\_install. | `string` | `"distro"` | no |
| <a name="input_ansible_playbooks"></a> [ansible\_playbooks](#input\_ansible\_playbooks) | n/a | <pre>list(object({<br/>    path       = string<br/>    inventory  = optional(string, "localhost,")<br/>    connection = optional(string, "local")<br/>    extra_vars = optional(map(string), {})<br/>    tags       = optional(list(string), [])<br/>    become     = optional(bool, true)<br/>  }))</pre> | `[]` | no |
| <a name="input_ansible_pull"></a> [ansible\_pull](#input\_ansible\_pull) | Native cc\_ansible, git-based only (ansible-pull clones a repo and runs it - cloud-init's docs describe a remote URL, not a local path). For a playbook you already have locally or in S3, use ansible\_playbooks instead, not this. | <pre>list(object({<br/>    url             = string<br/>    playbook_names  = list(string)<br/>    checkout        = optional(string)<br/>    accept_host_key = optional(bool, true)<br/>    full            = optional(bool)<br/>    clean           = optional(bool)<br/>    timeout         = optional(number)<br/>  }))</pre> | `[]` | no |
| <a name="input_apt"></a> [apt](#input\_apt) | Maps to cc\_apt\_configure - Debian/Ubuntu only, no-op on other distros. sources is keyed by an arbitrary source id. | <pre>object({<br/>    preserve_sources_list = optional(bool)<br/>    disable_suites        = optional(list(string), [])<br/>    sources = optional(map(object({<br/>      source    = string<br/>      keyid     = optional(string)<br/>      key       = optional(string)<br/>      keyserver = optional(string)<br/>    })), {})<br/>  })</pre> | `null` | no |
| <a name="input_artifacts"></a> [artifacts](#input\_artifacts) | Files to fetch onto the compute before ansible\_playbooks/execution\_steps run, using whatever identity it already has - never a static credential. source scheme picks the mechanism: s3://bucket/key (AWS IAM instance role via the aws CLI), gs://bucket/object (GCP attached service account via gcloud), azblob://account/container/blob (Azure Managed Identity via az, auth-mode login), or https://... (plain curl, no identity needed). Large content belongs here, not in cloud\_config/shell\_scripts - never embed big payloads as base64 in user\_data. region/endpoint\_url only apply to s3:// (endpoint\_url also covers S3-compatible object storage, e.g. Hetzner Object Storage, MinIO). | <pre>list(object({<br/>    source       = string<br/>    destination  = string<br/>    owner        = optional(string)<br/>    permissions  = optional(string)<br/>    sha256       = optional(string)<br/>    region       = optional(string)<br/>    endpoint_url = optional(string)<br/>    extract      = optional(bool, false)<br/>    extract_to   = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_boot_commands"></a> [boot\_commands](#input\_boot\_commands) | Maps to bootcmd - runs every boot, early (Network stage). Must be idempotent - cloud-init does not enforce this, it's the caller's responsibility. | `any` | `[]` | no |
| <a name="input_ca_certs"></a> [ca\_certs](#input\_ca\_certs) | n/a | <pre>object({<br/>    trusted         = optional(list(string), [])<br/>    remove_defaults = optional(bool, false)<br/>  })</pre> | `null` | no |
| <a name="input_cloud_config"></a> [cloud\_config](#input\_cloud\_config) | Arbitrary cloud-config directives as a plain HCL object - escape hatch for anything the typed helpers below don't cover, or future cloud-init keys. Rendered as one text/cloud-config part, the #cloud-config header added automatically. A top-level key set here AND by a typed helper is a hard error - pick one mechanism per key. | `any` | `null` | no |
| <a name="input_cloudinit_parts"></a> [cloudinit\_parts](#input\_cloudinit\_parts) | Escape hatch for anything else - arbitrary MIME parts (custom content\_type, filename, merge\_type). Appended last, after every other part this module generates. | <pre>list(object({<br/>    content_type = string<br/>    content      = string<br/>    filename     = optional(string)<br/>    merge_type   = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_commands"></a> [commands](#input\_commands) | Maps to runcmd - runs once per instance, late in boot (Final stage), after packages/users/write\_files. Each entry is a shell string or an argv-style list. | `any` | `[]` | no |
| <a name="input_device_aliases"></a> [device\_aliases](#input\_device\_aliases) | Maps to the top-level device\_aliases key - lets disk\_setup/fs\_setup/mounts reference a device by name instead of a raw path. | `map(string)` | `{}` | no |
| <a name="input_disk_setup"></a> [disk\_setup](#input\_disk\_setup) | Maps to cc\_disk\_setup, keyed by device (or a device\_aliases name). overwrite = true is destructive - cloud-init's own docs call this out explicitly. | <pre>map(object({<br/>    table_type = optional(string, "mbr")<br/>    layout     = optional(any, false)<br/>    overwrite  = optional(bool, false)<br/>  }))</pre> | `{}` | no |
| <a name="input_execution_steps"></a> [execution\_steps](#input\_execution\_steps) | Ordered shell commands run after artifacts are fetched and ansible\_playbooks run - e.g. executing a downloaded .sh script, or starting a service. | <pre>list(object({<br/>    command = string<br/>    cwd     = optional(string)<br/>    env     = optional(map(string), {})<br/>  }))</pre> | `[]` | no |
| <a name="input_files"></a> [files](#input\_files) | Maps to cc\_write\_files. Keyed by destination path for a stable, deterministic order. permissions is an octal string (e.g. "0644"); encoding matches cloud-init's enum (text/plain, b64, gzip, gzip+base64, ...); defer delays the write until after users/packages are set up. | <pre>map(object({<br/>    content     = optional(string, "")<br/>    owner       = optional(string, "root:root")<br/>    permissions = optional(string, "0644")<br/>    encoding    = optional(string, "text/plain")<br/>    append      = optional(bool, false)<br/>    defer       = optional(bool, false)<br/>    source_uri  = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_fqdn"></a> [fqdn](#input\_fqdn) | n/a | `string` | `null` | no |
| <a name="input_fs_setup"></a> [fs\_setup](#input\_fs\_setup) | Maps to cc\_fs\_setup. overwrite = true is destructive, same caveat as disk\_setup. | <pre>list(object({<br/>    label      = optional(string)<br/>    filesystem = string<br/>    device     = string<br/>    partition  = optional(string)<br/>    overwrite  = optional(bool, false)<br/>    extra_opts = optional(list(string), [])<br/>  }))</pre> | `[]` | no |
| <a name="input_groups"></a> [groups](#input\_groups) | Maps to cc\_users\_groups's `groups` key - map of group name to a username or list of usernames to add to it. | `map(list(string))` | `null` | no |
| <a name="input_growpart"></a> [growpart](#input\_growpart) | n/a | <pre>object({<br/>    mode                     = optional(string, "auto")<br/>    devices                  = optional(list(string), ["/"])<br/>    ignore_growroot_disabled = optional(bool, false)<br/>  })</pre> | `null` | no |
| <a name="input_gzip"></a> [gzip](#input\_gzip) | Gzip the rendered payload. AWS EC2's user\_data size limit applies to the data as submitted (post-gzip, pre-base64) - enable this if the combined payload is large enough to hit max\_bytes. cloud-init on Linux decompresses gzip automatically. | `bool` | `false` | no |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | n/a | `string` | `null` | no |
| <a name="input_max_bytes"></a> [max\_bytes](#input\_max\_bytes) | Raw (decoded, post-gzip) byte limit to validate against - AWS EC2's limit (16384) by default. | `number` | `16384` | no |
| <a name="input_mounts"></a> [mounts](#input\_mounts) | Maps to cc\_mounts - cloud-init's native fstab-tuple shape: [fs\_spec, fs\_file, fs\_vfstype, fs\_mntops, fs\_freq, fs\_passno], trailing fields omittable. Use a stable device identifier (UUID=.../LABEL=...), not a raw /dev/xvd* path - naming can differ between the guest OS and the EBS attachment on Nitro instances. | `list(list(string))` | `[]` | no |
| <a name="input_ntp"></a> [ntp](#input\_ntp) | n/a | <pre>object({<br/>    enabled    = optional(bool, true)<br/>    ntp_client = optional(string)<br/>    pools      = optional(list(string), [])<br/>    servers    = optional(list(string), [])<br/>  })</pre> | `null` | no |
| <a name="input_packages"></a> [packages](#input\_packages) | Maps to cc\_package\_update\_upgrade\_install. install: plain names, [name, version] pairs, or manager-scoped {apt = [...], snap = [...]}. update/upgrade default false (never forced silently). | <pre>object({<br/>    install            = optional(any, [])<br/>    update             = optional(bool, false)<br/>    upgrade            = optional(bool, false)<br/>    reboot_if_required = optional(bool, false)<br/>  })</pre> | `null` | no |
| <a name="input_phone_home"></a> [phone\_home](#input\_phone\_home) | n/a | <pre>object({<br/>    url   = string<br/>    post  = optional(list(string), ["instance_id", "hostname", "fqdn"])<br/>    tries = optional(number, 10)<br/>  })</pre> | `null` | no |
| <a name="input_power_state"></a> [power\_state](#input\_power\_state) | Reboot/poweroff at the end of cloud-init's run. Opt-in only (null = do nothing). | <pre>object({<br/>    mode      = string<br/>    delay     = optional(string, "now")<br/>    message   = optional(string)<br/>    timeout   = optional(number, 30)<br/>    condition = optional(string, "true")<br/>  })</pre> | `null` | no |
| <a name="input_preserve_hostname"></a> [preserve\_hostname](#input\_preserve\_hostname) | n/a | `bool` | `false` | no |
| <a name="input_resize_rootfs"></a> [resize\_rootfs](#input\_resize\_rootfs) | true, false, or "noblock" (resize in the background instead of blocking boot). | `string` | `null` | no |
| <a name="input_rsyslog"></a> [rsyslog](#input\_rsyslog) | n/a | <pre>object({<br/>    configs = optional(list(string), [])<br/>    remotes = optional(map(string), {})<br/>  })</pre> | `null` | no |
| <a name="input_scripts"></a> [scripts](#input\_scripts) | Frequency-scoped shell scripts, beyond the plain shell\_scripts (text/x-shellscript). per\_boot runs every boot; per\_instance runs once per new instance id; per\_once runs exactly once ever; boothook runs earliest of all, as root, every boot. | <pre>object({<br/>    per_boot     = optional(list(string), [])<br/>    per_instance = optional(list(string), [])<br/>    per_once     = optional(list(string), [])<br/>    boothook     = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_secrets"></a> [secrets](#input\_secrets) | Files materialized at boot by a generated oneshot service (name in the secrets\_service output) - secret values never enter user-data or state, only the path or command that produces them. Exactly one of source\_path (copy a file already on the instance) or command (its stdout becomes the content, e.g. a secrets-manager CLI call). | <pre>list(object({<br/>    name        = string<br/>    destination = string<br/>    source_path = optional(string)<br/>    command     = optional(string)<br/>    owner       = optional(string)<br/>    permissions = optional(string, "0600")<br/>  }))</pre> | `[]` | no |
| <a name="input_shell_scripts"></a> [shell\_scripts](#input\_shell\_scripts) | Shell scripts to run, in order - each becomes one text/x-shellscript part (cloud-init's default/legacy script type, runs once per instance via the user-data module). | `list(string)` | `[]` | no |
| <a name="input_ssh"></a> [ssh](#input\_ssh) | n/a | <pre>object({<br/>    enabled              = optional(bool, true)<br/>    emit_keys_to_console = optional(bool, true)<br/>  })</pre> | `null` | no |
| <a name="input_ssh_authorized_keys"></a> [ssh\_authorized\_keys](#input\_ssh\_authorized\_keys) | Top-level ssh\_authorized\_keys - a list of public keys. | `list(string)` | `[]` | no |
| <a name="input_ssh_deletekeys"></a> [ssh\_deletekeys](#input\_ssh\_deletekeys) | Delete the AMI's existing host keys before generating new ones - on by default upstream to avoid every instance from one AMI sharing host keys. | `bool` | `null` | no |
| <a name="input_ssh_genkeytypes"></a> [ssh\_genkeytypes](#input\_ssh\_genkeytypes) | Host key types to generate, e.g. ["rsa", "ecdsa", "ed25519"]. Null uses cloud-init's own default set. | `list(string)` | `null` | no |
| <a name="input_swap"></a> [swap](#input\_swap) | Maps to the top-level swap key (a swapfile, not a swap partition). size/maxsize accept "auto" or a byte count/suffixed string (e.g. "512M"). | <pre>object({<br/>    filename = string<br/>    size     = optional(string, "auto")<br/>    maxsize  = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_systemd_units"></a> [systemd\_units](#input\_systemd\_units) | systemd units written to /etc/systemd/system (unit file plus optional drop-ins in the unit's .d dir); daemon-reload and systemctl enable run in runcmd, before commands[]. enabled requires an [Install] section in the unit content. | <pre>list(object({<br/>    name    = string<br/>    type    = optional(string, "service")<br/>    content = string<br/>    enabled = optional(bool, false)<br/>    dropins = optional(map(string), {})<br/>  }))</pre> | `[]` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | IANA timezone name (e.g. "America/Los\_Angeles", "UTC") - as found in /usr/share/zoneinfo. | `string` | `null` | no |
| <a name="input_users"></a> [users](#input\_users) | Maps to cc\_users\_groups's `users` key. Each entry is cloud-init's full user object shape (name required; groups/sudo/ssh\_authorized\_keys/etc. - see cloud-init's users\_groups docs for the complete field set, passed through as-is via `extra`). | <pre>list(object({<br/>    name                = string<br/>    gecos               = optional(string)<br/>    groups              = optional(list(string))<br/>    shell               = optional(string)<br/>    sudo                = optional(string)<br/>    lock_passwd         = optional(bool, true)<br/>    ssh_authorized_keys = optional(list(string))<br/>    ssh_import_id       = optional(list(string))<br/>    passwd              = optional(string)<br/>    hashed_passwd       = optional(string)<br/>    plain_text_passwd   = optional(string)<br/>    system              = optional(bool, false)<br/>    uid                 = optional(number)<br/>    primary_group       = optional(string)<br/>    homedir             = optional(string)<br/>    no_create_home      = optional(bool, false)<br/>    expiredate          = optional(string)<br/>    selinux_user        = optional(string)<br/>    extra               = optional(any, {})<br/>  }))</pre> | `null` | no |
| <a name="input_yum_repos"></a> [yum\_repos](#input\_yum\_repos) | Maps to cc\_yum\_add\_repo, keyed by repo id. Each needs exactly one of baseurl/metalink/mirrorlist (passed via extra) - other yum.conf keys (enabled, gpgcheck, ...) go in extra too. | <pre>map(object({<br/>    baseurl = optional(string)<br/>    extra   = optional(any, {})<br/>  }))</pre> | `{}` | no |

### Outputs

| Name | Description |
|------|-------------|
| <a name="output_content_types"></a> [content\_types](#output\_content\_types) | content\_type of every part in the rendered payload, in order - useful for debugging without decoding the base64. |
| <a name="output_generated_cloud_config"></a> [generated\_cloud\_config](#output\_generated\_cloud\_config) | The merged cloud-config object before YAML/base64 rendering - for inspection, not consumption. May contain whatever sensitive content the caller put into files/users/cloud\_config. |
| <a name="output_has_user_data"></a> [has\_user\_data](#output\_has\_user\_data) | Whether any part was actually generated - lets a caller skip setting user\_data entirely rather than wiring in a null. |
| <a name="output_raw_bytes"></a> [raw\_bytes](#output\_raw\_bytes) | Decoded (post-gzip) size in bytes - compare against your platform's user\_data limit. |
| <a name="output_rendered"></a> [rendered](#output\_rendered) | Base64-encoded multipart MIME cloud-init payload, ready for a user\_data (or cloud-provider equivalent) argument. Null if there's nothing to render. |
| <a name="output_required_permissions"></a> [required\_permissions](#output\_required\_permissions) | Per-provider permission requirements for whatever artifacts[] sources are configured, keyed by provider - each null if that provider's scheme isn't used. This module never creates or attaches any of these; wire them into whatever identity the compute actually runs as (AWS IAM role, GCP service account, Azure Managed Identity). |
| <a name="output_secrets_service"></a> [secrets\_service](#output\_secrets\_service) | Name of the generated oneshot service that materializes secrets[] at boot - order consumers with After=/Requires=. Null if secrets is empty. |

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

```text
The MIT License (MIT)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files, to deal in the Software
without restriction.

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

Source: https://opensource.org/licenses/MIT
```


See [LICENSE](LICENSE) for full details.
## Authors

- Rafał Masiarek | [website](https://masiarek.pl) | [email](mailto:rafal@masiarek.pl) | [github](https://github.com/rafalmasiarek)


<!-- references -->

[repo_link]: https://github.com/rafalmasiarek/terraform-null-cloudinit
