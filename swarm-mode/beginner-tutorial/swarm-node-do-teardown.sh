#!/bin/bash
### Warning: This will remove all docker machines running ###
# Stop machines

docker-machine -s .docker/machine stop $(docker-machine -s .docker/machine ls -q)

# remove machines
docker-machine -s .docker/machine rm -f $(docker-machine -s .docker/machine ls -q)
