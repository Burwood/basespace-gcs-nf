FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:stable

# 1. Install Dependencies for BaseSpace CLI
# The BaseSpace CLI is typically a Python or shell script that requires 
# some standard Linux utilities. We'll use 'wget' to download the script.
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get update -y --allow-insecure-repositories && \
    apt-get install -y --no-install-recommends --allow-unauthenticated \
    wget \
    unzip \
    ca-certificates \
    curl \
    python3 \
    procps \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install the BaseSpace CLI (`bs`)
ENV BASESPACE_CLI_VERSION=latest

# Download, rename, and set permissions for the BaseSpace CLI
RUN wget "https://launch.basespace.illumina.com/CLI/${BASESPACE_CLI_VERSION}/amd64-linux/bs" \
    -O /usr/local/bin/bs && \
    chmod +x /usr/local/bin/bs

# 3. Verification
# Ensure both CLIs are available for the Nextflow process
RUN bs --version
RUN gcloud --version
RUN gsutil version
RUN ps --version

# Set the entrypoint or default command if needed, but for Nextflow, 
# the `nextflow.config` process command will override the entrypoint.
