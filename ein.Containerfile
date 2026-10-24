# EiN as compose runs it: core's own image (src/core/src/Containerfile, which setup.sh builds first
# as localhost/ein-core) with its web interface built in. The modules are not in it: EiN installs
# them into the data folder that compose.yaml mounts.
ARG CORE_IMAGE=localhost/ein-core
FROM ${CORE_IMAGE}

RUN deno task bundle-ui
