#!/bin/bash
set -ex
npm install -g appium@next
appium -v
appium driver install mac2
appium driver list