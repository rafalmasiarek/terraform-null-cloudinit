locals {
  s3_artifacts     = [for a in var.artifacts : a if startswith(a.source, "s3://")]
  gs_artifacts     = [for a in var.artifacts : a if startswith(a.source, "gs://")]
  azblob_artifacts = [for a in var.artifacts : a if startswith(a.source, "azblob://")]

  # awscli ships in every mainstream distro's default package repo - a
  # simple conditional install is reliable. gcloud/az do not (they need a
  # vendor repo added first), so those paths fail with a clear message
  # instead of attempting a fragile multi-step install.
  aws_cli_bootstrap = length(local.s3_artifacts) == 0 ? [] : [
    "if ! command -v aws >/dev/null 2>&1; then",
    "  if command -v dnf >/dev/null 2>&1; then dnf install -y awscli",
    "  elif command -v yum >/dev/null 2>&1; then yum install -y awscli",
    "  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y awscli",
    "  else echo 'artifacts: no supported package manager found to install aws-cli' >&2; exit 1",
    "  fi",
    "fi",
  ]

  gcloud_check = length(local.gs_artifacts) == 0 ? [] : [
    "if ! command -v gcloud >/dev/null 2>&1; then",
    "  echo 'artifacts: gs:// source requires the Google Cloud SDK (gcloud) pre-installed on this image - no reliable one-line install across distros, see https://cloud.google.com/sdk/docs/install' >&2",
    "  exit 1",
    "fi",
  ]

  az_cli_check = length(local.azblob_artifacts) == 0 ? [] : [
    "if ! command -v az >/dev/null 2>&1; then",
    "  echo 'artifacts: azblob:// source requires the Azure CLI (az) pre-installed on this image - no reliable one-line install across distros, see https://learn.microsoft.com/cli/azure/install-azure-cli' >&2",
    "  exit 1",
    "fi",
  ]

  cli_bootstrap = concat(local.aws_cli_bootstrap, local.gcloud_check, local.az_cli_check)

  azblob_parts_by_source = {
    for a in local.azblob_artifacts : a.source => regex("^azblob://([^/]+)/([^/]+)/(.+)$", a.source)
  }

  # One ordered list of shell lines per artifact - fetch (S3/GCS/Azure Blob
  # via the compute's own attached identity, or HTTPS), verify, own, chmod,
  # optionally extract. Never a static credential in any of these - AWS IAM
  # instance role, GCP attached service account, Azure Managed Identity are
  # each picked up automatically by their respective CLI.
  artifact_lines = flatten([
    for a in var.artifacts : concat(
      ["mkdir -p \"$(dirname \"${a.destination}\")\""],
      startswith(a.source, "s3://") ? [
        "aws s3 cp ${a.endpoint_url != null ? "--endpoint-url ${a.endpoint_url} " : ""}${a.region != null ? "--region ${a.region} " : ""}\"${a.source}\" \"${a.destination}\""
        ] : startswith(a.source, "gs://") ? [
        "gcloud storage cp \"${a.source}\" \"${a.destination}\""
        ] : startswith(a.source, "azblob://") ? [
        "az storage blob download --auth-mode login --account-name \"${local.azblob_parts_by_source[a.source][0]}\" --container-name \"${local.azblob_parts_by_source[a.source][1]}\" --name \"${local.azblob_parts_by_source[a.source][2]}\" --file \"${a.destination}\""
        ] : [
        "curl -fsSL -o \"${a.destination}\" \"${a.source}\""
      ],
      a.sha256 != null ? ["echo \"${a.sha256}  ${a.destination}\" | sha256sum -c -"] : [],
      a.owner != null ? ["chown ${a.owner} \"${a.destination}\""] : [],
      a.permissions != null ? ["chmod ${a.permissions} \"${a.destination}\""] : [],
      a.extract ? [
        "EXTRACT_DIR=\"${a.extract_to != null ? a.extract_to : "$(dirname \"${a.destination}\")"}\"",
        "mkdir -p \"$EXTRACT_DIR\"",
        "tar -xzf \"${a.destination}\" -C \"$EXTRACT_DIR\"",
      ] : [],
    )
  ])

  ansible_core_bootstrap = length(var.ansible_playbooks) == 0 || !var.ansible_core_install ? [] : [
    "if ! command -v ansible-playbook >/dev/null 2>&1; then",
    "  if command -v dnf >/dev/null 2>&1; then dnf install -y ansible-core",
    "  elif command -v yum >/dev/null 2>&1; then yum install -y ansible",
    "  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y ansible-core",
    "  else echo 'ansible_playbooks: no supported package manager found to install ansible-core' >&2; exit 1",
    "  fi",
    "fi",
  ]

  # Shell arguments are single-quoted (embedded quotes escaped as '\''); execution_steps[].command is trusted and left unquoted.
  ansible_playbook_lines = flatten([
    for p in var.ansible_playbooks : [
      join(" ", concat(
        ["ansible-playbook"],
        ["-i", "'${replace(p.inventory, "'", "'\\''")}'"],
        ["-c", "'${replace(p.connection, "'", "'\\''")}'"],
        p.become ? ["-b"] : [],
        length(p.tags) > 0 ? ["--tags", "'${replace(join(",", p.tags), "'", "'\\''")}'"] : [],
        length(p.extra_vars) > 0 ? ["--extra-vars", "'${replace(join(" ", [for k, v in p.extra_vars : "${k}=${v}"]), "'", "'\\''")}'"] : [],
        ["'${replace(p.path, "'", "'\\''")}'"],
      ))
    ]
  ])

  execution_step_lines = flatten([
    for s in var.execution_steps : concat(
      s.cwd != null ? ["cd '${replace(s.cwd, "'", "'\\''")}'"] : [],
      [join(" ", concat([for k, v in s.env : "${k}='${replace(v, "'", "'\\''")}'"], [s.command]))],
    )
  ])

  bootstrap_lines = concat(
    local.cli_bootstrap,
    local.artifact_lines,
    local.ansible_core_bootstrap,
    local.ansible_playbook_lines,
    local.execution_step_lines,
  )

  bootstrap_script = length(local.bootstrap_lines) == 0 ? null : join("\n", concat(
    ["#!/bin/bash", "set -euo pipefail"],
    local.bootstrap_lines,
  ))

  bootstrap_part = local.bootstrap_script == null ? [] : [{
    content_type = "text/x-shellscript"
    content      = local.bootstrap_script
    filename     = null
    merge_type   = null
  }]

  # Pure string/jsonencode construction, no cloud-provider provider required -
  # this module only renders user-data, it never provisions IAM/identity
  # resources itself. The caller attaches these to whatever identity the
  # compute actually runs as.
  s3_artifact_parts = [
    for a in local.s3_artifacts : regex("^s3://([^/]+)/(.+)$", a.source)
  ]

  aws_required_permissions = length(local.s3_artifact_parts) == 0 ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = [for p in local.s3_artifact_parts : "arn:aws:s3:::${p[0]}/${p[1]}"]
    }]
  })

  gcp_required_permissions = length(local.gs_artifacts) == 0 ? null : {
    role    = "roles/storage.objectViewer"
    objects = [for a in local.gs_artifacts : a.source]
  }

  azure_required_permissions = length(local.azblob_artifacts) == 0 ? null : {
    role  = "Storage Blob Data Reader"
    blobs = [for a in local.azblob_artifacts : "${local.azblob_parts_by_source[a.source][0]}/${local.azblob_parts_by_source[a.source][1]}/${local.azblob_parts_by_source[a.source][2]}"]
  }
}
