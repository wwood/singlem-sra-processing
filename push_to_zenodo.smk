import os
import json
import sys
from os.path import join

# Usage:
#   ZENODO_TOKEN=xxxx snakemake -s push_to_zenodo.smk --config version=2.0.0 -j 1
#
# Creates a new draft (unpublished) Zenodo version from the record specified by
# PARENT_RECORD_ID, populated with files from /work/microbiome/db/sandpiper/<version>.

VERSION = config["version"]
# Version of the source data dir to read files from; defaults to the release
# version, but may differ (e.g. release 2.0.1 built from the 2.0.0 data dir).
DATA_VERSION = config.get("data_version", VERSION)
INPUT_DIR = f"/work/microbiome/db/sandpiper/{DATA_VERSION}"
PARENT_RECORD_ID = "20419175"
ZENODO_BASE = "https://zenodo.org"

# Grant id prefixes the current Zenodo API refuses to validate (legacy DOE
# funder). Stripped before the metadata update; tuple for str.startswith().
INVALID_GRANT_PREFIXES = ("0114b2m14::",)

# Working dir for outputs/logs, since INPUT_DIR (/work) may be read-only.
WORK_DIR = join("zenodo_drafts", VERSION)

# upload_name -> existing source file in INPUT_DIR to upload under that name
UPLOAD_MAP = {
    f"sandpiper{VERSION}.gtdb.csv.gz": "condensed.csv.gz",
    f"sandpiper{VERSION}.kingfisher_metadata.tsv.gz": "kingfisher_metadata.tsv.gz",
    f"sandpiper{VERSION}.parsed_metadata.tsv.gz": "parsed_metadata.tsv.gz",
    f"sandpiper{VERSION}.per_acc_summary.csv.gz": "per_acc_summary.csv.gz",
}

os.makedirs(join(WORK_DIR, "logs"), exist_ok=True)


rule all:
    input:
        join(WORK_DIR, "zenodo_draft.url"),


rule create_zenodo_draft:
    output:
        url_file=join(WORK_DIR, "zenodo_draft.url"),
    log:
        join(WORK_DIR, "logs", "zenodo_draft.log"),
    benchmark:
        join(WORK_DIR, "logs", "zenodo_draft.benchmark")
    run:
        import requests

        with open(log[0], "w") as logf:

            def lprint(*args):
                print(*args, file=logf, flush=True)

            token = os.environ.get("ZENODO_TOKEN")
            if not token:
                msg = "ZENODO_TOKEN environment variable not set"
                lprint(f"ERROR: {msg}")
                sys.exit(msg)

            params = {"access_token": token}
            api = f"{ZENODO_BASE}/api"

            lprint(f"Fetching deposition {PARENT_RECORD_ID}")
            r = requests.get(
                f"{api}/deposit/depositions/{PARENT_RECORD_ID}", params=params
            )
            r.raise_for_status()

            lprint("Creating new draft version")
            r = requests.post(
                f"{api}/deposit/depositions/{PARENT_RECORD_ID}/actions/newversion",
                params=params,
            )
            r.raise_for_status()
            latest_draft_url = r.json()["links"]["latest_draft"]
            lprint(f"Latest draft url: {latest_draft_url}")

            r = requests.get(latest_draft_url, params=params)
            r.raise_for_status()
            draft = r.json()
            new_id = draft["id"]
            bucket_url = draft["links"]["bucket"]
            html_url = draft["links"].get("html", f"{ZENODO_BASE}/deposit/{new_id}")
            lprint(f"New draft id: {new_id}")
            lprint(f"Bucket url: {bucket_url}")

            # The newversion action copies the previous version's files into the draft.
            # Remove them so the draft only contains the freshly-uploaded files.
            for f in draft.get("files", []):
                fid = f["id"]
                fname = f.get("filename", fid)
                lprint(f"Removing inherited file {fname}")
                del_r = requests.delete(
                    f"{api}/deposit/depositions/{new_id}/files/{fid}",
                    params=params,
                )
                del_r.raise_for_status()

            for upload_name, source in UPLOAD_MAP.items():
                real = join(INPUT_DIR, source)
                if not os.path.exists(real):
                    raise FileNotFoundError(f"Source file does not exist: {real}")
                size = os.path.getsize(real)
                lprint(f"Uploading {upload_name} ({size} bytes) from {real}")
                with open(real, "rb") as fh:
                    up = requests.put(
                        f"{bucket_url}/{upload_name}", data=fh, params=params
                    )
                    up.raise_for_status()

            metadata = draft.get("metadata", {})
            metadata["version"] = VERSION
            # Drop grants the current Zenodo API rejects (the DOE funder
            # 0114b2m14:: grants validate fine in the legacy web UI but 400 via
            # the API). Re-add them in the web UI before publishing if needed.
            grants = metadata.get("grants")
            if grants:
                kept = [g for g in grants if not g.get("id", "").startswith(INVALID_GRANT_PREFIXES)]
                dropped = [g["id"] for g in grants if g not in kept]
                if dropped:
                    lprint(f"Dropping API-invalid grants (re-add in web UI): {dropped}")
                metadata["grants"] = kept
            lprint(f"Updating metadata version to {VERSION}")
            meta_r = requests.put(
                f"{api}/deposit/depositions/{new_id}",
                params=params,
                data=json.dumps({"metadata": metadata}),
                headers={"Content-Type": "application/json"},
            )
            if not meta_r.ok:
                lprint(f"ERROR {meta_r.status_code}: {meta_r.text}")
            meta_r.raise_for_status()

            with open(output.url_file, "w") as outf:
                outf.write(html_url + "\n")

            lprint(f"Draft release available at {html_url}")


onsuccess:
    with open(join(WORK_DIR, "zenodo_draft.url")) as f:
        url = f.read().strip()
    print(
        f"Draft release available at {url}, but GlobDB needs to be handled separately"
    )
