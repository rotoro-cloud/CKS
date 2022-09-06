FROM ubuntu:22.10

RUN apt update && apt install -y gcc libc6 libc-bin

COPY wait-for-runc-and-overwrite.sh /
COPY exploit.c /

WORKDIR /
RUN gcc exploit.c -o exploit

CMD ["./wait-for-runc-and-overwrite.sh"]
