FROM mcr.microsoft.com/dotnet/sdk:{{ instance.dotnet_sdk }}-noble
# Ubuntu 24.04

ENV DEBIAN_FRONTEND=noninteractive

# Use a mirror for faster downloads in CI
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://eu-west-1.ec2.archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    sed -i 's|http://security.ubuntu.com/ubuntu/|http://eu-west-1.ec2.archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update

# Install common packages
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    sudo \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# (Optional) Install additional dotnet SDK versions if tests target multiple frameworks
# RUN wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh && \
#     chmod +x ./dotnet-install.sh && \
#     ./dotnet-install.sh --version 6.0.428 --install-dir /usr/share/dotnet

RUN git clone https://github.com/{{ instance.owner }}/{{ instance.repo_name }}.git /app
WORKDIR /app
RUN git checkout {{ instance.base_commit }}

# Pre-restore dependencies for faster eval runs
RUN dotnet restore

LABEL ee-bench.type="codegen"
LABEL ee-bench.version="1.0"
RUN rm -rf /app/.ee-bench/ 2>/dev/null || true
