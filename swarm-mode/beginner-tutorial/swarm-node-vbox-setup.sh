#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# BEGIN DECLARATIONS
MACHINE_STORAGE_PATH="${PWD}/.docker/machine"
VIRTUALBOX_CPU_COUNT=2
VIRTUALBOX_MEMORY_SIZE=2048
export MACHINE_STORAGE_PATH VIRTUALBOX_CPU_COUNT VIRTUALBOX_MEMORY_SIZE

declare -a SERVER_NAMEN
declare -a managers
declare -a workers

########################################################################################################################
#BEGIN VARIABLES                                                                                                       #
########################################################################################################################

SERVER_NAMEN=( manager1 manager2 manager3 worker1 worker2 worker3 ) ; export SERVER_NAMEN
managers=( 0 1 2 ) ; export managers 
workers=( 3 4 5 ) ; export workers

# END DECLARATIONS

# Swarm mode using Docker Machine

# create manager machines
echo "======> Creating ${#managers[@]} manager machines ...";
for node in ${!managers[@]};
do
	(
	echo "======> Creating ${SERVER_NAMEN[${managers[$node]}]} as manager machine ...";
	docker-machine create -d virtualbox ${SERVER_NAMEN[${managers[$node]}]};
	) &
    managers_pids[${node}]=$!
done

# create worker machines
echo "======> Creating ${#managers[@]} worker machines ...";
for node in ${!workers[@]};
do
	(
	echo "======> Creating ${SERVER_NAMEN[${workers[$node]}]} as worker machine ...";
	docker-machine create -d virtualbox ${SERVER_NAMEN[${workers[$node]}]};
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

# list all machines
docker-machine ls

# initialize swarm mode and create a manager
echo "======> Initializing first swarm manager ..."
SWARM_MANAGER1_NAME="${SERVER_NAMEN[${managers[0]}]}" ; export SWARM_MANAGER1_NAME
SWARM_MANAGER1_IP="$(docker-machine ip ${SWARM_MANAGER1_NAME})" ; export SWARM_MANAGER1_IP
docker-machine ssh ${SWARM_MANAGER1_NAME} "docker swarm init --listen-addr ${SWARM_MANAGER1_IP} --advertise-addr ${SWARM_MANAGER1_IP}"

# get manager and worker tokens
export manager_token=`docker-machine ssh ${SWARM_MANAGER1_NAME} "docker swarm join-token manager -q"`
export worker_token=`docker-machine ssh ${SWARM_MANAGER1_NAME} "docker swarm join-token worker -q"`

echo "manager_token: $manager_token"
echo "worker_token: $worker_token"

# other masters join swarm
managers_slice=( "${managers[@]:1}" )
for node in ${!managers_slice[@]};
do
	echo "======>  ${SERVER_NAMEN[${managers_slice[$node]}]} joining swarm as manager ..."
	swarm_host_name="${SERVER_NAMEN[${managers_slice[$node]}]}"
	docker-machine ssh ${swarm_host_name} \
	"docker swarm join \
	--token $manager_token \
	--listen-addr $(docker-machine ip ${swarm_host_name}) \
	--advertise-addr $(docker-machine ip ${swarm_host_name}) \
	${SWARM_MANAGER1_IP}"
done

# show members of swarm
docker-machine ssh "${SWARM_MANAGER1_NAME}" "docker node ls"

# workers join swarm
for node in ${!workers[@]};
do
	echo "======>  ${SERVER_NAMEN[${workers[$node]}]} joining swarm as worker ..."
	swarm_host_name="${SERVER_NAMEN[${workers[$node]}]}"
	docker-machine ssh ${swarm_host_name} \
	"docker swarm join \
	--token $worker_token \
	--listen-addr $(docker-machine ip ${swarm_host_name}) \
	--advertise-addr $(docker-machine ip ${swarm_host_name}) \
	${SWARM_MANAGER1_IP}"
done

# show members of swarm
docker-machine ssh "${SWARM_MANAGER1_NAME}" "docker node ls"

