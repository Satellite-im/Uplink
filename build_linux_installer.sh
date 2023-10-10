#!/bin/bash

PACKAGE_NAME=$1
PACKAGE_VERSION=$2
PACKAGE_ARCHITECTURE=$3

FULL_NAME="${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCHITECTURE}"
FILES_DIR=./ui/deb
BUILD_DIR=./target/$FULL_NAME

DATE=`date +%y-%m-%d`

mkdir -p ${BUILD_DIR}
cp -r $FILES_DIR/* ${BUILD_DIR}/

sed -i "s/{{package}}/${PACKAGE_NAME}/g"              ${BUILD_DIR}/DEBIAN/control
sed -i "s/{{version}}/${PACKAGE_VERSION}/g"           ${BUILD_DIR}/DEBIAN/control
sed -i "s/{{architecture}}/${PACKAGE_ARCHITECTURE}/g" ${BUILD_DIR}/DEBIAN/control

sed -i "s/{{version}}/${PACKAGE_VERSION}/g" ${BUILD_DIR}/usr/share/applications/im.satellite.uplink.desktop
sed -i "s/{{version}}/${PACKAGE_VERSION}/g" ${BUILD_DIR}/usr/share/metainfo/im.satellite.uplink.metainfo.xml
sed -i "s/{{date}}/${DATE}/g"               ${BUILD_DIR}/usr/share/metainfo/im.satellite.uplink.metainfo.xml

# delete any directories created by this script
rm -rf                                  ${BUILD_DIR}/opt
rm -rf                                  ${BUILD_DIR}/usr/share/icons

mkdir -p                                ${BUILD_DIR}/opt/im.satellite/extra
mkdir -p                                ${BUILD_DIR}/usr/share/icons/im.satellite/
mkdir                                   ${BUILD_DIR}/opt/im.satellite/extensions

cp target/release/${PACKAGE_NAME}       ${BUILD_DIR}/opt/im.satellite/${PACKAGE_NAME}

cp -r ./ui/extra/assets                 ${BUILD_DIR}/opt/im.satellite/extra
cp -r ./ui/extra/images                 ${BUILD_DIR}/opt/im.satellite/extra
cp -r ./ui/extra/prism_langs            ${BUILD_DIR}/opt/im.satellite/extra
cp -r ./ui/extra/themes                 ${BUILD_DIR}/opt/im.satellite/extra

cp ./ui/extra/images/logo.png           ${BUILD_DIR}/usr/share/icons/im.satellite/uplink_logo.png

cp -r target/release/*.so               ${BUILD_DIR}/opt/im.satellite/extensions

dpkg-deb -Z gzip --root-owner-group --build ${BUILD_DIR} target/release/${FULL_NAME}.deb
sha256sum target/release/${FULL_NAME}.deb > target/release/SHA256SUM
