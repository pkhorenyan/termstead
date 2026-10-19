# A small SSH server for Termstead's test lab: one user, `lab`, who can log in
# with a key or with the password `lab`, and who may forward TCP — which is what
# makes a host usable as a jump host.
FROM alpine:3.20

# busybox-extras brings httpd: each host serves a page on port 80, inside the
# lab's networks only, for trying port forwarding on.
RUN apk add --no-cache openssh-server bash busybox-extras \
 && adduser -D -s /bin/bash lab \
 && echo "lab:lab" | chpasswd \
 && mkdir -p /home/lab/.ssh && chmod 700 /home/lab/.ssh && chown -R lab:lab /home/lab/.ssh \
 && rm -f /etc/ssh/ssh_host_*

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
