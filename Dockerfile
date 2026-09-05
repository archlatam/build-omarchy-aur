# Imagen de build para paquetes AUR sobre Arch Linux (rolling).
# - base-devel: herramientas de makepkg (gcc, make, fakeroot...)
# - git:        clonado de paquetes AUR
# - sudo:       makepkg -s necesita instalar dependencias con pacman
FROM archlinux:latest

RUN pacman -Syu --noconfirm \
        base-devel \
        git \
        sudo \
    && pacman -Scc --noconfirm

# Escaneo de seguridad del PKGBUILD, ejecutado antes de makepkg.
COPY scan-pkgbuild.sh /usr/local/bin/scan-pkgbuild.sh
RUN chmod +x /usr/local/bin/scan-pkgbuild.sh

# makepkg se niega a ejecutarse como root: se usa el usuario "build".
# NOPASSWD solo para poder resolver dependencias de forma automatica.
RUN useradd -m -G wheel build \
    && printf 'build ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/build \
    && chmod 440 /etc/sudoers.d/build