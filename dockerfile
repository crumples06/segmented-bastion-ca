FROM ubuntu:24.04
RUN apt-get update && apt-get install -y openssh-server sudo && rm -f /etc/ssh/ssh_host_*
RUN useradd -m -s /bin/bash admin && mkdir -p /var/run/sshd
RUN mkdir -p /home/admin/.ssh 
COPY ./keys/key.pub /home/admin/.ssh/authorized_keys
RUN chown -R admin:admin /home/admin/.ssh && chmod 700 /home/admin/.ssh && chmod 600 /home/admin/.ssh/authorized_keys
EXPOSE 22
COPY ./host_keygen.sh /usr/local/bin
RUN chmod +x /usr/local/bin/host_keygen.sh
COPY hardening.conf /etc/ssh/sshd_config.d/hardening.conf
ENTRYPOINT [ "/usr/local/bin/host_keygen.sh" ]