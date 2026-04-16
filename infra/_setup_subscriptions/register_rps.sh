#!/bin/bash

# Define options
OPTIONS="s:f:nh"
LONGOPTIONS="subscriptionId:,file:,nowait,help"
PARSED=$(getopt --options "$OPTIONS" --longoptions "$LONGOPTIONS" --name "$(basename "$0")" -- "$@")
eval set -- "$PARSED"

# Initializa parameters
subscriptionId=
resourceProvidersFile=./resource_providers.txt
nowait=false

if [[ $? -ne 0 ]]; then
  # If getopt fails, exit with an error
  exit 1
fi

# Process options
while true; do
  case "$1" in
    -s|--subscriptionId) subscriptionId=$2;        shift 2 ;;
    -f|--file)           resourceProvidersFile=$2; shift 2 ;;
    -n|--nowait)         nowait=true; shift 1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [options]"
      echo "Options:"
      echo "  -s, --subscriptionId  Azure Subscription Id to register resource providers"
      echo "  -f, --file            A filename taht contains a list of Resource Providers to be registered"
      echo "  -n, --nowait          No wait for Resource Providers registration"
      echo "  -h, --help            Show this help message"
      echo ""
      shift;
      exit 1;
      ;;
    --) shift; break ;;
    *) echo "Invalid option"; exit 1 ;;
  esac
done

az account set --subscription $subscriptionId || exit 1

for rp in `cat ${resourceProvidersFile}`; do
  state=$(az provider show --namespace ${rp} --query "registrationState" -o tsv)
  if [ "$state" != "Registered" ]; then
    echo -n "Registering Resource Provider $rp... "
    if [ "$nowait" != "true" ]; then
      az provider register --namespace ${rp} --wait && echo "Registered" || echo "Failed to register!"
    else
      az provider register --namespace ${rp} && echo "(check later)"
    fi
  else
    echo "Resource provider $rp is already registered."
  fi
done
