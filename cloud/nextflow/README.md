# Pipeline1.nf

Proof of concept that singlem works with nextflow and specified env.

```
conda activate <from ../docker/env.yaml>

PATH=~/git/singlem/bin:$PATH nextflow run pipeline1.nf
```

# Pipeline2_docker.nf

Getting it to work in docker not conda.

To generate the docker image:

```
docker$ DOCKER_BUILDKIT=1 docker build -f plastic.Dockerfile -t singlem:0.16.0-dev4.b27c15b0-plastic3 .
```

```
nextflow run pipeline2_docker.nf -with-docker singlem:0.16.0-dev4.b27c15b0-plastic3
```

# Pipeline2_input_file.nf

Want to input a list of SRA IDs, not just one
```

```