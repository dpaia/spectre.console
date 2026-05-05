FROM mcr.microsoft.com/dotnet/sdk:9.0

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    NUGET_XMLDOC_MODE=skip

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      python3 && \
    rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/{{ instance.owner }}/{{ instance.repo_name }}.git /app
WORKDIR /app
RUN git checkout {{ instance.base_commit }}

RUN dotnet restore "{{ instance.test_project }}" && \
    dotnet build --no-restore {{ instance.test_framework_flag }} "{{ instance.test_project }}"

LABEL ee-bench.type="codegen"
LABEL ee-bench.version="1.0"
RUN rm -rf /app/.ee-bench/ 2>/dev/null || true
