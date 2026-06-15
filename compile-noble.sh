# build debian 11 image for orangepi 4 pro
./build.sh  BOARD=orangepi4pro \
  BRANCH=current \
  BUILD_OPT=image \
  RELEASE=noble \
  BUILD_DESKTOP=yes \
  BUILD_MINIMAL=no \
  KERNEL_CONFIGURE=no \
  DESKTOP_ENVIRONMENT=xfce \
  DESKTOP_ENVIRONMENT_CONFIG_NAME=config_base \
  DESKTOP_APPGROUPS_SELECTED="" \
  DESKTOP_APT_FLAGS_SELECTED="htop"