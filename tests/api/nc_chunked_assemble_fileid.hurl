# =============================================================
# OxiCloud — the chunked-assemble MOVE answers with OC-FileId
# =============================================================
# The NextCloud desktop client uploads anything bigger than its chunk
# size (10 MB by default) as MKCOL → PUT chunks → MOVE `.file`. After
# that MOVE it reads `OC-FileId` (`PropagateUploadFileNG::
# slotMoveJobFinished`). Without the header it aborts with "Missing
# File ID from server" and retries the whole upload on every sync,
# although the assembled file did land: every file over 10 MB looped
# forever. Plain PUT uploads were unaffected, because that path only
# reads the header when it is present.
#
# Two properties are pinned, both read by the client:
#
#   1. The value is the file's `oc:id` (`{:08}{instance_id}`), the same
#      string PROPFIND reports. The client journals the header and
#      compares it with later PROPFINDs, so the bare numeric
#      `oc:fileid` would make every file look replaced.
#   2. It survives an overwrite: a second chunked upload to the same
#      path answers with the same id. A new id makes the client log
#      "File ID changed!" and treat the file as a different one.
#
# Self-contained: mints its own app password and deletes its probe
# file plus the app password in teardown, so it can run alongside the
# rest of the suite.
# =============================================================


# ─────────────────────────────────────────────────────────────
# Setup — JWT login, then mint an NC app password (NC DAV uses
#         Basic Auth, not the JWT bearer token).
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
jwt: jsonpath "$.access_token"


POST {{base_url}}/api/auth/app-passwords
Authorization: Bearer {{jwt}}
Content-Type: application/json
{ "label": "nc_chunked_assemble_fileid" }

HTTP 200
[Captures]
nc_username: jsonpath "$.username"
nc_password: jsonpath "$.password"
ap_id:       jsonpath "$.id"


# ═════════════════════════════════════════════════════════════
# Part A — a new file: the MOVE carries OC-FileId, and it is the
#          file's oc:id
# ═════════════════════════════════════════════════════════════
MKCOL {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-1
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 201


PUT {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-1/00001
[BasicAuth]
{{nc_username}}: {{nc_password}}
```
first chunk
```

HTTP 201


PUT {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-1/00002
[BasicAuth]
{{nc_username}}: {{nc_password}}
```
second chunk
```

HTTP 201


# Hurl gotcha, as in `nc_webdav_client_mtime.hurl`: headers MUST precede
# `[BasicAuth]`, or `Destination:` is parsed as a new request's method line.
MOVE {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-1/.file
Destination: {{base_url}}/remote.php/dav/files/{{username}}/nc-fileid-chunked.txt
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 201
[Captures]
assembled_oc_id: header "OC-FileId"
[Asserts]
# THE regression: this header was absent, which is what made the desktop
# client loop on every chunked upload.
header "OC-FileId" exists
# `{:08}{instance_id}`, never a bare number: digits alone mean the numeric
# `oc:fileid` leaked into the header. (The PROPFIND below pins the exact
# value.)
header "OC-FileId" not matches "^[0-9]+$"


PROPFIND {{base_url}}/remote.php/dav/files/{{username}}/nc-fileid-chunked.txt
Depth: 0
Content-Type: application/xml; charset=utf-8
[BasicAuth]
{{nc_username}}: {{nc_password}}
```
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:oc="http://owncloud.org/ns">
  <D:prop>
    <oc:id/>
  </D:prop>
</D:propfind>
```

HTTP 207
[Asserts]
# Property 1: the header and PROPFIND agree, so the id the client journals
# after the upload matches what its next discovery reads.
xpath "string(//*[local-name()='id'])" == "{{assembled_oc_id}}"


# ═════════════════════════════════════════════════════════════
# Part B — an overwrite through a second chunked upload keeps the id
# ═════════════════════════════════════════════════════════════
MKCOL {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-2
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 201


PUT {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-2/00001
[BasicAuth]
{{nc_username}}: {{nc_password}}
```
replacement content
```

HTTP 201


MOVE {{base_url}}/remote.php/dav/uploads/{{username}}/nc-fileid-session-2/.file
Destination: {{base_url}}/remote.php/dav/files/{{username}}/nc-fileid-chunked.txt
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 201
[Asserts]
# Property 2: same file, same id. A new id here makes the client log
# "File ID changed!" and treat the overwrite as a different file.
header "OC-FileId" == "{{assembled_oc_id}}"


# ═════════════════════════════════════════════════════════════
# Teardown
# ═════════════════════════════════════════════════════════════
DELETE {{base_url}}/remote.php/dav/files/{{username}}/nc-fileid-chunked.txt
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 204


DELETE {{base_url}}/api/auth/app-passwords/{{ap_id}}
Authorization: Bearer {{jwt}}

HTTP 200
