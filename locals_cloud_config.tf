locals {
  # Every *_cfg below is one object literal with a fixed, unconditional set
  # of top-level keys - values are null when unset, never omitted. A
  # ternary between differently-shaped objects ({} vs {key=...}) breaks
  # Terraform's type unification ("inconsistent conditional result types");
  # null unifies with anything, so nulling a value is safe where omitting
  # a key is not. Nulls are stripped once, at the very end, from the fully
  # merged result.

  packages_cfg = {
    packages                   = var.packages != null && length(var.packages.install) > 0 ? var.packages.install : null
    package_update             = var.packages != null ? var.packages.update : null
    package_upgrade            = var.packages != null ? var.packages.upgrade : null
    package_reboot_if_required = var.packages != null ? var.packages.reboot_if_required : null
  }

  users_list = var.users == null ? null : [
    for u in var.users : merge(
      { name = u.name },
      {
        for k, v in {
          gecos               = u.gecos
          groups              = u.groups
          shell               = u.shell
          sudo                = u.sudo
          lock_passwd         = u.lock_passwd
          ssh_authorized_keys = u.ssh_authorized_keys
          ssh_import_id       = u.ssh_import_id
          passwd              = u.passwd
          hashed_passwd       = u.hashed_passwd
          plain_text_passwd   = u.plain_text_passwd
          system              = u.system
          uid                 = u.uid
          primary_group       = u.primary_group
          homedir             = u.homedir
          no_create_home      = u.no_create_home
          expiredate          = u.expiredate
        } : k => v if v != null
      },
      u.extra,
    )
  ]

  users_cfg  = { users = local.users_list }
  groups_cfg = { groups = var.groups }

  ssh_authorized_keys_cfg = {
    ssh_authorized_keys = length(var.ssh_authorized_keys) > 0 ? var.ssh_authorized_keys : null
  }

  files_list = [
    for path in sort(keys(var.files)) : merge(
      { path = path },
      {
        for k, v in {
          content     = var.files[path].content
          owner       = var.files[path].owner
          permissions = var.files[path].permissions
          encoding    = var.files[path].encoding
          append      = var.files[path].append
          defer       = var.files[path].defer
        } : k => v if v != null
      },
      var.files[path].source_uri != null ? { source = { uri = var.files[path].source_uri } } : {},
    )
  ]
  write_files_cfg = { write_files = length(local.files_list) > 0 ? local.files_list : null }

  commands_cfg      = { runcmd = length(var.commands) > 0 ? var.commands : null }
  boot_commands_cfg = { bootcmd = length(var.boot_commands) > 0 ? var.boot_commands : null }

  hostname_cfg = {
    hostname          = var.hostname
    fqdn              = var.fqdn
    preserve_hostname = var.preserve_hostname ? true : null
  }

  timezone_cfg = { timezone = var.timezone }

  mounts_cfg = { mounts = length(var.mounts) > 0 ? var.mounts : null }

  swap_cfg = {
    swap = var.swap == null ? null : {
      for k, v in var.swap : k => v if v != null
    }
  }

  growpart_cfg = {
    growpart = var.growpart == null ? null : {
      for k, v in var.growpart : k => v if v != null
    }
  }

  resize_rootfs_cfg = { resize_rootfs = var.resize_rootfs }

  disk_setup_cfg = {
    disk_setup = length(var.disk_setup) > 0 ? { for k, v in var.disk_setup : k => v } : null
  }

  fs_setup_cfg = {
    fs_setup = length(var.fs_setup) > 0 ? [
      for f in var.fs_setup : { for k, v in f : k => v if v != null }
    ] : null
  }

  device_aliases_cfg = { device_aliases = length(var.device_aliases) > 0 ? var.device_aliases : null }

  ssh_cfg             = { ssh = var.ssh }
  ssh_genkeytypes_cfg = { ssh_genkeytypes = var.ssh_genkeytypes }
  ssh_deletekeys_cfg  = { ssh_deletekeys = var.ssh_deletekeys }

  ca_certs_cfg = {
    ca_certs = var.ca_certs == null ? null : {
      for k, v in var.ca_certs : k => v if v != null && v != []
    }
  }

  ntp_cfg = {
    ntp = var.ntp == null ? null : {
      for k, v in {
        enabled    = var.ntp.enabled
        ntp_client = var.ntp.ntp_client
        pools      = length(var.ntp.pools) > 0 ? var.ntp.pools : null
        servers    = length(var.ntp.servers) > 0 ? var.ntp.servers : null
      } : k => v if v != null
    }
  }

  apt_cfg = {
    apt = var.apt == null ? null : {
      for k, v in {
        preserve_sources_list = var.apt.preserve_sources_list
        disable_suites        = length(var.apt.disable_suites) > 0 ? var.apt.disable_suites : null
        sources = length(var.apt.sources) > 0 ? {
          for id, s in var.apt.sources : id => { for k, v in s : k => v if v != null }
        } : null
      } : k => v if v != null
    }
  }

  yum_repos_cfg = {
    yum_repos = length(var.yum_repos) > 0 ? {
      for id, r in var.yum_repos : id => merge(
        r.baseurl != null ? { baseurl = r.baseurl } : {},
        r.extra,
      )
    } : null
  }

  ansible_cfg = {
    ansible = length(var.ansible_pull) == 0 ? null : {
      install_method = var.ansible_install_method
      pull = [
        for p in var.ansible_pull : { for k, v in p : k => v if v != null }
      ]
    }
  }

  power_state_cfg = {
    power_state = var.power_state == null ? null : {
      for k, v in var.power_state : k => v if v != null
    }
  }

  phone_home_cfg = {
    phone_home = var.phone_home == null ? null : {
      for k, v in var.phone_home : k => v if v != null
    }
  }

  rsyslog_cfg = {
    rsyslog = var.rsyslog == null ? null : {
      for k, v in var.rsyslog : k => v if v != null
    }
  }

  generated_cloud_config_raw = merge(
    local.packages_cfg,
    local.users_cfg,
    local.groups_cfg,
    local.ssh_authorized_keys_cfg,
    local.write_files_cfg,
    local.commands_cfg,
    local.boot_commands_cfg,
    local.hostname_cfg,
    local.timezone_cfg,
    local.mounts_cfg,
    local.swap_cfg,
    local.growpart_cfg,
    local.resize_rootfs_cfg,
    local.disk_setup_cfg,
    local.fs_setup_cfg,
    local.device_aliases_cfg,
    local.ssh_cfg,
    local.ssh_genkeytypes_cfg,
    local.ssh_deletekeys_cfg,
    local.ca_certs_cfg,
    local.ntp_cfg,
    local.apt_cfg,
    local.yum_repos_cfg,
    local.ansible_cfg,
    local.power_state_cfg,
    local.phone_home_cfg,
    local.rsyslog_cfg,
  )

  generated_cloud_config = {
    for k, v in local.generated_cloud_config_raw : k => v if v != null
  }

  # The only real conflict risk is a key set by BOTH a typed helper and the
  # raw cloud_config escape hatch - silently letting one win would hide a
  # caller mistake, so this is a hard error instead (see the precondition
  # on cloud_config_conflict_check below).
  cloud_config_overlap = var.cloud_config == null ? [] : setintersection(
    toset(keys(local.generated_cloud_config)),
    toset(keys(var.cloud_config)),
  )

  cloud_config_merged = merge(local.generated_cloud_config, var.cloud_config != null ? var.cloud_config : {})
}

resource "terraform_data" "cloud_config_conflict_check" {
  count = length(local.generated_cloud_config) > 0 || var.cloud_config != null ? 1 : 0

  input = true

  lifecycle {
    precondition {
      condition     = length(local.cloud_config_overlap) == 0
      error_message = "cloud_config sets key(s) [${join(", ", local.cloud_config_overlap)}] that a typed helper variable also sets - pick one mechanism per key, don't set both."
    }
  }
}
