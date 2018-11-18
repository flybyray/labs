#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# BEGIN DECLARATIONS
MACHINE_STORAGE_PATH="${PWD}/.docker/machine" ; export MACHINE_STORAGE_PATH

DIGITALOCEAN_ACCESS_TOKEN="$(>&2 echo "PUT YOUR DO TOKEN HERE"; exit 1)" ; export DIGITALOCEAN_ACCESS_TOKEN
# get a list of images:
# total_as_per_page=$( curl -X GET -H "Content-Type: application/json" -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/images?page=1&per_page=1&type=distribution"  | jq '.meta.total' )
# curl -X GET -H "Content-Type: application/json" -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/images?page=1&per_page=${total_as_per_page}&type=distribution" | jq -r '.images[] | select(.distribution | contains("Ubuntu")).slug'
DIGITALOCEAN_IMAGE="ubuntu-18-04-x64" ; export DIGITALOCEAN_IMAGE
DIGITALOCEAN_PRIVATE_NETWORKING="true" ; export DIGITALOCEAN_PRIVATE_NETWORKING
# get a list of regions:
# curl -X GET -H "Content-Type: application/json" -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/regions" | jq -r '.regions[].slug'
DIGITALOCEAN_REGION="fra1" ; export DIGITALOCEAN_REGION
# get a list of sizes:
# curl -X GET -H "Content-Type: application/json" -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/sizes" | jq -r '.sizes[].slug'
DIGITALOCEAN_SIZE="512mb" ; export DIGITALOCEAN_SIZE


managers=3
workers=3

declare -a VALID_SSH_KEY_NAMES
# to get a list of possible names run:
# curl -fsSL -X GET -H "Content-Type: application/json" -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/account/keys" | jq -r ".ssh_keys[].name"
VALID_SSH_KEY_NAMES=(
"user1@mail.com"
"$(>&2 echo "PUT YOUR DO SSH_KEY.NAME's"; exit 1)"
"user2@mail.com"
)
# END DECLARATIONS

function jqFilterValidSSHKeyNames() {
for i in "${!VALID_SSH_KEY_NAMES[@]}"; do
 printf '%s' "contains(\"${VALID_SSH_KEY_NAMES[i]}\")"
 if [ $(expr ${i} + 1) -eq ${#VALID_SSH_KEY_NAMES[@]} ]
 then
  continue
 fi
 printf '%s' " or "
done
}
export -f jqFilterValidSSHKeyNames

function getPublicKeys() {
for keyid in \
  $(
    curl \
      -fsSL \
      -X GET \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/account/keys" \
        | \
        jq \
          -r ".ssh_keys[] | select(.name | $(jqFilterValidSSHKeyNames)).id" \
  )
do
  curl \
    -fsSL \
    -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "https://api.digitalocean.com/v2/account/keys/${keyid%$'\r'}" \
      | \
      jq \
        -r '.ssh_key.public_key'
done
}
export -f getPublicKeys

echo "======> Getting additional ssh public keys ...";
PUBLIC_KEYS="$(getPublicKeys)" ; export PUBLIC_KEYS

# Swarm mode using Docker Machine

# create manager machines
echo "======> Creating $managers manager machines ...";
for node in $(seq 1 $managers);
do
	(
	echo "======> Creating manager$node machine ...";
	docker-machine create -d digitalocean manager$node;
	echo "${PUBLIC_KEYS}" | docker-machine ssh manager$node "tee -a ~/.ssh/authorized_keys"
	) &
    managers_pids[${node}]=$!
done

# create worker machines
echo "======> Creating $workers worker machines ...";
for node in $(seq 1 $workers);
do
	(
	echo "======> Creating worker$node machine ...";
	docker-machine create -d digitalocean worker$node;
	echo "${PUBLIC_KEYS}" | docker-machine ssh worker$node "tee -a ~/.ssh/authorized_keys"
	) &
    workers_pids[${node}]=$!
done

echo "======> Waiting for background jobs ...";
jobs -p
echo "======> Waiting for managers nodes ...";
for pid in ${managers_pids[*]}; do
  wait $pid
done
echo "======> Waiting for workers nodes ...";
for pid in ${workers_pids[*]}; do
  wait $pid
done

echo "======> list all machines ...";
docker-machine ls

# initialize swarm mode and create a manager
echo "======> Initializing first swarm manager ..."
docker-machine ssh manager1 "docker swarm init --listen-addr eth1:2377 --advertise-addr eth1:2377"

MANAGER1_SWARM_NODEID="$(docker $(docker-machine -s .docker/machine config manager1) info --format '{{json .}}' | jq -r '.Swarm.NodeID')" ; export MANAGER1_SWARM_NODEID
MANAGER1_SWARM_ADDR="$(docker $(docker-machine -s .docker/machine config manager1) info --format '{{json .}}' | jq -r '.Swarm.RemoteManagers[] | select(.NodeID | contains("'${MANAGER1_SWARM_NODEID}'")).Addr')" ; export MANAGER1_SWARM_ADDR

# get manager and worker tokens
export manager_token=`docker-machine ssh manager1 "docker swarm join-token manager -q"`
export worker_token=`docker-machine ssh manager1 "docker swarm join-token worker -q"`

echo "manager_token: $manager_token"
echo "worker_token: $worker_token"

# other masters join swarm
for node in $(seq 2 $managers);
do
	echo "======> manager$node joining swarm as manager ..."
	docker-machine ssh manager$node \
		"docker swarm join \
		--token $manager_token \
		--listen-addr eth1:2377 \
		--advertise-addr eth1:2377 \
		${MANAGER1_SWARM_ADDR}"
done

# show members of swarm
docker-machine ssh manager1 "docker node ls"

# workers join swarm
for node in $(seq 1 $workers);
do
	echo "======> worker$node joining swarm as worker ..."
	docker-machine ssh worker$node \
	"docker swarm join \
	--token $worker_token \
	--listen-addr eth1:2377 \
	--advertise-addr eth1:2377 \
    ${MANAGER1_SWARM_ADDR}"
done

# show members of swarm
docker-machine ssh manager1 "docker node ls"

