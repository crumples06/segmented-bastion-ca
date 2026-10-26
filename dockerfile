FROM ubuntu:24.04

# Installing openssh-server auto-generates host keys, so every container from this image 
# will have the same host keys, so I have to delete and then recreate them in containers later
RUN apt-get update && apt-get install -y openssh-server sudo python3 && rm -f /etc/ssh/ssh_host_*

# we create the sshd directory as containers often dont have it
RUN useradd -m -s /bin/bash admin && mkdir -p /var/run/sshd

# grants admin paswwordless sudo to run anything as root, chmod 440 is mandatory
# sudo silently ignores sudoers files whose permissions arent 440
RUN echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin
EXPOSE 22

COPY ./host_keygen.sh /usr/local/bin
RUN chmod +x /usr/local/bin/host_keygen.sh

COPY hardening.conf /etc/ssh/sshd_config.d/hardening.conf

# Installs a user CA public key, the server trusts any user certificate signed by this CA (as setup in hardening.conf)
COPY ./ca/user_ca.pub /etc/ssh/user_ca.pub

ENTRYPOINT [ "/usr/local/bin/host_keygen.sh" ]