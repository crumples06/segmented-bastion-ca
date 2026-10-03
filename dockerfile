FROM ubuntu:24.04
RUN apt-get update && apt-get install -y openssh-server sudo && rm -f /etc/ssh/ssh_host_*
RUN useradd -m -s /bin/bash admin && mkdir -p /var/run/sshd
EXPOSE 22
COPY ./host_keygen.sh /usr/local/bin
RUN chmod +x /usr/local/bin/host_keygen.sh
COPY hardening.conf /etc/ssh/sshd_config.d/hardening.conf
COPY ./ca/user_ca.pub /etc/ssh/user_ca.pub
ENTRYPOINT [ "/usr/local/bin/host_keygen.sh" ]