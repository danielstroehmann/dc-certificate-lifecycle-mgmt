#!/bin/bash
set -euo pipefail

sudo apt update
sudo apt install -y software-properties-common

sudo add-apt-repository -y ppa:yubico/stable
sudo apt update

sudo apt install -y \
  yubikey-manager \
  ykcs11 \
  opensc \
  libengine-pkcs11-openssl \
  openssl \
  curl
