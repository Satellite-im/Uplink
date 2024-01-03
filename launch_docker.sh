#!/bin/sh

# arguments: 
# $1: the docker container to run. ex: uplink-runner
# $2: the docker volume to mount. ex: warp2

# example docker file

# description
# bind the local X11 port to the docker container, allowing the docker container to execute GUI applications on Linux. 

# from ubuntu:22.04
# 
# RUN apt-get update && apt-get install -y \
# 	x11-apps \
# 	xauth
# 
# RUN apt-get install -y \
# 	libwebkit2gtk-4.0-37
# 
# RUN mkdir  /root/.uplink
# WORKDIR /root/bin
# 
# CMD ["bash"]

docker run -ti --rm --net=host --ipc=host -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix -v `pwd`/target:/root/bin -v $2:/root/.uplink $1 /bin/bash
