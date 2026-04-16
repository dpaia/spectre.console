FROM mcr.microsoft.com/dotnet/sdk:8.0-jammy
# 8.0 because it was built on ubuntu 22.04 and repository required libssl1.1 which available for ubuntu 22.04.
# For ubuntu 24.04 libssl3 is installed.

ENV DEBIAN_FRONTEND=noninteractive

# Ubuntu server blocks a lot of requests, so we use a mirror (version to Ubuntu 22 and older)
RUN sed -i 's|http://.*.ubuntu.com|http://eu-west-1.ec2.archive.ubuntu.com|g' /etc/apt/sources.list && apt-get update

# Install common packages
RUN apt-get update && \
    apt-get install -y software-properties-common && \
    add-apt-repository -y ppa:git-core/ppa && \
    apt-get update && \
    apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    sudo \
    tar \
    zip \
    unzip \
    autoconf \
    # Required for env
    libcurl4-gnutls-dev \
    libexpat1-dev \
    mono-complete \
    # Required for installing Git
    zlib1g-dev \
    gettext \
    # Required for Junie
    libsecret-1-0 \
    libsecret-1-dev \
    rsync \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y wget && \
    wget http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.0g-2ubuntu4_amd64.deb && \
    dpkg -i libssl1.1_1.1.0g-2ubuntu4_amd64.deb

RUN wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh && \
    chmod +x ./dotnet-install.sh && \
    ./dotnet-install.sh --version 9.0.300 --install-dir /usr/share/dotnet

RUN wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh && \
    chmod +x ./dotnet-install.sh && \
    ./dotnet-install.sh --version 8.0.410 --install-dir /usr/share/dotnet && \
    ./dotnet-install.sh --version 7.0.410 --install-dir /usr/share/dotnet && \
    ./dotnet-install.sh --version 6.0.428 --install-dir /usr/share/dotnet && \
    ./dotnet-install.sh --version 5.0.301 --install-dir /usr/share/dotnet

ENV PATH="/usr/share/dotnet:${PATH}"

# Install Python 3.10
RUN apt-get update && \
    apt-get install -y software-properties-common curl && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y python3.10 python3.10-distutils && \
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 && \
    python --version

RUN git clone https://github.com/{{ instance.owner }}/{{ instance.repo_name }}.git /app
WORKDIR /app
RUN git checkout {{ instance.base_commit }}

RUN dotnet add "./test/Spectre.Console.Analyzer.Tests/Spectre.Console.Analyzer.Tests.csproj" package JUnitTestLogger || true && \
    dotnet add "./test/Spectre.Console.Tests/Spectre.Console.Tests.csproj" package JUnitTestLogger || true && \
    dotnet add "./test/Spectre.Console.Cli.Tests/Spectre.Console.Cli.Tests.csproj" package JUnitTestLogger || true && \
    dotnet add "./src/Tests/Spectre.Console.Tests/Spectre.Console.Tests.csproj" package JUnitTestLogger || true && \
    dotnet build "./src/Spectre.Console.sln"

LABEL ee-bench.type="codegen"
LABEL ee-bench.version="1.0"
RUN rm -rf /app/.ee-bench/ 2>/dev/null || true
