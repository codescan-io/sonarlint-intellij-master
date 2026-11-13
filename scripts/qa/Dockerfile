# Linux desktop for running a real IntelliJ IDEA on a virtual screen (Xvfb).
# The IDE itself is not baked in: it is unpacked at run time from a mounted tarball,
# so one image serves every IDE version. The IDE brings its own JDK.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -o Acquire::http::Timeout=60 -o Acquire::Retries=3 update \
 && apt-get -o Acquire::http::Timeout=60 -o Acquire::Retries=3 install -y --no-install-recommends \
      xvfb fluxbox xdotool x11-apps x11-utils imagemagick tesseract-ocr \
      fontconfig fonts-dejavu-core libfreetype6 \
      libxext6 libxrender1 libxtst6 libxi6 libxrandr2 libasound2t64 \
      git unzip procps ca-certificates \
      libnss3 libnspr4 libgbm1 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libpango-1.0-0 libcairo2 libdbus-1-3 libxshmfence1 \
 && rm -rf /var/lib/apt/lists/*

# The lib* packages from libnss3 on are for the IDE's embedded browser (JCEF); without them
# it fails to start and logs a SEVERE error that a real desktop would not have.

# Without a UTF-8 locale Java cannot read non-ASCII file names such as
# /etc/ssl/certs/NetLock_Arany_=Class_Gold=_Főtanúsítvány.pem, and the CodeScan backend fails to start.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# A normal user, as on a developer machine (as root the IDE turns off the embedded browser).
RUN useradd -m -s /bin/bash qa && mkdir -p /opt/idea /work && chown qa:qa /opt/idea /work
USER qa
ENV DISPLAY=:99
