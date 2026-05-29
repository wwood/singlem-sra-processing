Processing of public metagenomic data that has been analysed with SingleM.

Most code here is not intended for public usage as many paths etc are specific to CMR / QUT / Woodcroft group, but nonetheless may be useful for others.

# Post-processing a singlem renew run of SRA data

First modify paths at the top of the Snakemake
    
Then setup:
```
pixi install --all
```

and run
```
pixi run snakemake --cores 1
```

Make sure the correct taxonomic level is chosen for applying predictions in the Snakemake file. See 
`{base_output_directory}/logs/host_or_not_prediction.log` for the results of the cross validation.

# Host-vs-not metagenome prediction

Example code for host-vs-not prediction is contained within the `Snakefile`. In 

# Publishing a release to Zenodo

`push_to_zenodo.smk` creates a new **draft** (unpublished) Zenodo version of the
sandpiper record from the data in `/work/microbiome/db/sandpiper/<data_version>`.
It bases the new version on the published parent record (`PARENT_RECORD_ID` near
the top of the file), uploads the gtdb / per-acc-summary / parsed-metadata /
kingfisher-metadata files (renamed to `sandpiper<version>.*`), removes the files
inherited from the previous version, and sets the version metadata.

Run it with the API token in the environment:
```
ZENODO_TOKEN="$(cat ~/.zenodo_draft_release_api_token)" \
  pixi run snakemake -s push_to_zenodo.smk --config version=2.0.1 -j 1
```

- `version` sets the Zenodo version and the uploaded filenames.
- `data_version` (optional) is the source data dir under
  `/work/microbiome/db/sandpiper/` to read from; defaults to `version`. Use it to
  build a release from a different data dir, e.g. `version=2.0.1 data_version=2.0.0`.
- Logs and the resulting draft URL are written under `zenodo_drafts/<version>/`
  (kept local because `/work` is often mounted read-only).

The draft is **not published** — review it in the Zenodo web UI and publish
manually. Two things still need handling by hand before publishing:

- The **GlobDB** file (`sandpiper<x>.globdb.csv.gz`) is uploaded separately.
- Grants under the legacy DOE funder (`0114b2m14::`, the `DE-SC...` grants) are
  rejected by the current Zenodo API and are dropped automatically; re-add them
  in the web UI if they are needed.
