#!/bin/bash

PACKAGE_NAME=$1
PACKAGE_VERSION=$2
PACKAGE_ARCHITECTURE=$3

FULL_NAME="${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCHITECTURE}"
FILES_DIR=./ui/deb-config
BUILD_DIR=./target/$FULL_NAME

mkdir -p ${BUILD_DIR}
cp -r $FILES_DIR/* ${BUILD_DIR}/

sed -i "s/{{package}}/${PACKAGE_NAME}/g" ${BUILD_DIR}/DEBIAN/control
sed -i "s/{{version}}/${PACKAGE_VERSION}/g" ${BUILD_DIR}/DEBIAN/control
sed -i "s/{{architecture}}/${PACKAGE_ARCHITECTURE}/g" ${BUILD_DIR}/DEBIAN/control

cp target/release/${PACKAGE_NAME} ${BUILD_DIR}/opt/satellite-im/${PACKAGE_NAME}

dpkg-deb -Z gzip --root-owner-group --build ${BUILD_DIR} target/release/${FULL_NAME}.deb
sha256sum target/release/${FULL_NAME}.deb > target/release/SHA256SUM
