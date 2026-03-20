# Docker image

Build docker image with the `wwood/sylph` `add-merge-subcommand` branch baked in and smoke-tested via `sylph sketch --interleaved`:
```bash
docker build -f sylph_build_from_source.Dockerfile . -t lamber22/sylph
```

Open image with
```bash
docker run -it lamber22/sylph
```
