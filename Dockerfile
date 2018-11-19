FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install jq

COPY gcp-snapshotter.sh /
