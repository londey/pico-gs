# pico-gs FPGA Development Container
FROM ubuntu:24.04

# Avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y \
    # Build essentials
    build-essential \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    # For USB/FPGA programming
    libftdi1-2 \
    libftdi1-dev \
    libudev-dev \
    usbutils \
    # Python (used by some FPGA tools)
    python3 \
    python3-pip \
    python3-venv \
    # Utilities
    make \
    sudo \
    locales \
    && rm -rf /var/lib/apt/lists/*

# Set up locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Install Node.js 20.x LTS (required for Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Rust via rustup (required for sysdoc)
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="${CARGO_HOME}/bin:${PATH}"

# Install uv package manager (required for spec-kit)
# Install to /opt/cargo/bin so it's available to all users
ENV UV_INSTALL_DIR=/opt/cargo/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install sysdoc from git
RUN cargo install --git https://github.com/sysdoc-rs/sysdoc.git

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Download and install oss-cad-suite
ARG OSS_CAD_SUITE_VERSION=20260127
ARG OSS_CAD_SUITE_DATE=2026-01-27
ENV OSS_CAD_SUITE_PATH=/opt/oss-cad-suite

RUN mkdir -p /opt \
    && cd /opt \
    && wget -q "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_DATE}/oss-cad-suite-linux-x64-${OSS_CAD_SUITE_VERSION}.tgz" \
    && tar -xzf oss-cad-suite-linux-x64-${OSS_CAD_SUITE_VERSION}.tgz \
    && rm oss-cad-suite-linux-x64-${OSS_CAD_SUITE_VERSION}.tgz

# Create non-root user for development (handle existing UID/GID 1000)
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

RUN if getent group ${USER_GID} > /dev/null 2>&1; then \
    existing_group=$(getent group ${USER_GID} | cut -d: -f1); \
    groupmod -n ${USERNAME} ${existing_group}; \
    else \
    groupadd --gid ${USER_GID} ${USERNAME}; \
    fi \
    && if getent passwd ${USER_UID} > /dev/null 2>&1; then \
    existing_user=$(getent passwd ${USER_UID} | cut -d: -f1); \
    usermod -l ${USERNAME} -d /home/${USERNAME} -m ${existing_user}; \
    else \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME}; \
    fi \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# Add user to dialout and plugdev groups for USB access
RUN usermod -aG dialout,plugdev ${USERNAME}

# Create .claude directory for user
RUN mkdir -p /home/${USERNAME}/.claude \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.claude

# Set up oss-cad-suite environment in bashrc
RUN echo '# OSS CAD Suite environment' >> /home/${USERNAME}/.bashrc \
    && echo 'export OSS_CAD_SUITE_PATH=/opt/oss-cad-suite' >> /home/${USERNAME}/.bashrc \
    && echo 'source ${OSS_CAD_SUITE_PATH}/environment' >> /home/${USERNAME}/.bashrc

# Add Rust/Cargo to path in bashrc
# Use user-specific CARGO_HOME so vscode user can download crates and install tools
RUN echo '# Rust environment' >> /home/${USERNAME}/.bashrc \
    && echo 'export CARGO_HOME="${HOME}/.cargo"' >> /home/${USERNAME}/.bashrc \
    && echo 'export PATH="/opt/cargo/bin:${HOME}/.cargo/bin:${PATH}"' >> /home/${USERNAME}/.bashrc

# Add uv to path in bashrc
RUN echo '# uv package manager' >> /home/${USERNAME}/.bashrc \
    && echo 'export PATH="/home/${USERNAME}/.local/bin:${PATH}"' >> /home/${USERNAME}/.bashrc

# Install spec-kit as vscode user
USER ${USERNAME}
RUN uv tool install specify-cli --from git+https://github.com/github/spec-kit.git

# Switch back to root for final setup
USER root

# Final user switch for workdir
USER ${USERNAME}
WORKDIR /workspaces
