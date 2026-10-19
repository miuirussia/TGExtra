FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang curl ca-certificates perl libgnustep-base-dev \
    && rm -rf /var/lib/apt/lists/*

# Same SDK repository as the release workflow; pin the compiler inputs.
RUN mkdir -p /opt/logos /opt/ios-sdk \
    && curl -fsSL https://codeload.github.com/theos/logos/tar.gz/777925d1add4ee3485a2432a6f6d5e3ded59de7b \
       | tar -xz --strip-components=1 -C /opt/logos \
    && curl -fsSL https://codeload.github.com/waruhachi/sdks/tar.gz/a7b81140aa8ce18b6e6a48846d4e63476b1e5709 \
       | tar -xz --strip-components=1 -C /opt/ios-sdk --wildcards '*/iPhoneOS16.5.sdk/*'

ENV LOGOS_PL=/opt/logos/bin/logos.pl
ENV IOS_SDK=/opt/ios-sdk/iPhoneOS16.5.sdk
WORKDIR /work
CMD ["bash", "Tests/menu_entry.sh"]
