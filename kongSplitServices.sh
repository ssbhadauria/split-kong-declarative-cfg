#!/bin/bash

################################################################################
#### This script splits a declarative Kong Yaml into individual services. ######
#==============================================================================#
#### Date : 02/07/2023 #########################################################
#### Written: Shantanu Bhadauria ###############################################
#### Owned: Kong Inc. ##########################################################
#### Disclaimer: This script is not managed and is unsupported. Customers once##
####             have it, have to update and maintain themselves. ##############  
#==============================================================================#
#### Step#1 : Can take deck dump directly from a Kong environment and use it ###
####          as input file to split. OR. Kong config file can directly be #####
####          used as input file. ##############################################
#### Step#2 : Each service is split into its own yaml config. All the service ##
####          objects including upstreams will be part of this service config. #
#### Step#3 : Each service config will be added with an info array. This will ##
####          contain list of tags under select_tags: . Now each service has ###
####          its own unique tag(s). This script uses only one tag and that is #
####          service name itself. #############################################
#==============================================================================#
################################################################################

#### Help and usage #####

usage() {
  cat <<EOF
OPTION 1 :
==========
##Get deck dump config for a given workspace and then split##
syntax: ./kongSplitServices.sh -u <admin-api-url> -w <my-workspace> -t <my-token> -e <environment>

system requirements: "yq" and "deck" utilities need to installed!

OPTION 2 :
==========
##Input deck dump config for a given workspace and then split##
syntax: ./kongSplitServices.sh -f <Kong Config File> -w <my-workspace> -e <environment>

system requirements: "yq" utility need to installed!

"kongSplitServices.sh" input parameters:
  
  ::Required
  -u|--url <admin api host name>
  -t|--token <admin api token>
  -e|--env <Kong Deployment environment (like Dev, QA, Prod etc)>
  -f|--file <Input Kong Config File>

  ::Optional
  -w|--workspace <workspace from where config is targeted to be exported (default all-workspaces)>
  -p|--port <admin api port> (default 8001)
  -h|--protocol <http or https (default http)>
  --help (Script help)
  --debug (run script in debug mode)
EOF
exit 1
}

################################
#### User input parameters #####
################################

while [[ $# -gt 0 ]]
do
  case $1 in
  -u|--url)
    AAPIURL=$2
    shift
    ;;
  -t|--token)
    TOKEN=$2
    shift
    ;;
  -e|--env)
    ENV=$2
    shift
    ;;
  -w|--workspace)
    WORKSPACE=$2
    shift
    ;;
  -f|--file)
    INFILE=$2
    shift
    ;;
  -p|--port)
    PORT=$2
    shift
    ;;
  -h|--protocol)
    PCOL=$2
    shift
    ;;
  --debug)
    set -x
    ;;
  --help)
    usage
    ;;
  esac
  shift
done

##############################
###### Error handling ########
##############################
if [[ -z "$WORKSPACE" ]];then
  WS=
  WORKSPACE=--all-workspaces
else
  WS=-w
fi
if [[ -z "$PCOL" ]];then
  PCOL=http
fi
if [[ -z "$PORT" ]];then
  PORT=8001
fi
if [[ -z "$ENV" ]];then
  echo "error: Kong Deployment environment is required!"
  usage
else
  mkdir "$ENV" 2>/dev/null
fi
if [[ -z "$INFILE" ]];then
  if [[ -z "$AAPIURL" ]];then
    echo "error: Admin API URL required!"
    usage
  else
    if [[ -z "$TOKEN" ]];then
      echo "error: Kong Admin Token is required!"
      usage
    else
      deck dump "$WS" "$WORKSPACE" --kong-addr "$PCOL"://"$AAPIURL":"$PORT" --headers kong-admin-token:"$TOKEN" -o "$ENV"/"$ENV"_"$WORKSPACE".yaml
    fi
  fi
else
  cp "$INFILE" "$ENV"/"$ENV"_"$WORKSPACE".yaml
fi
if [ -z "$INFILE" -a -z  "$AAPIURL" -a -z "$TOKEN" ];then
    echo "error: Input error, please check the usage!"
    usage
fi

#SVCS=$(yq '.services[].name' <"$ENV"/"$ENV"_"$WORKSPACE".yaml)
yq '.services[].name' <"$ENV"/"$ENV"_"$WORKSPACE".yaml|sed -e 's/^ *//g;s/ *$//g'|sed '/^$/d' >"$ENV"/"$ENV"_"$WORKSPACE".services

##########################################
#### read services from kong config  #####
##########################################

echo "###---######---### $(date +"%Y-%m-%d:%s") ###---######---###" >"$ENV"/"$ENV"_"$WORKSPACE".logs
while read service
if [[ -z "$service" ]];then
break 2
fi
echo "### $service ###" >> "$ENV"/"$ENV"_"$WORKSPACE".logs
echo "=================================================" >> "$ENV"/"$ENV"_"$WORKSPACE".logs
do
  yq '.services| map(select(.name == "'$service'"))'< "$ENV"/"$ENV"_"$WORKSPACE".yaml > "$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml
  yq -i '{"services": .}' "$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml
  ##########################################################################################################
  #### discover all upstreams for a each service if there is route by header or canary plugin or both  #####
  ##########################################################################################################
  UPSTNM=$(yq '.services[]|select(.plugins[]|.name =="route-by-header")|.plugins[]|select(.name == "route-by-header")|.config.rules[].upstream_name'<"$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml)
  if [[ -z "$(echo $UPSTNM|tr " " "\n"|sed '/^$/d')" ]];then
    #####################################################################################
    #### discover upstream for a each service if service host points to a upstream  #####
    #####################################################################################
    UPSTNM=$(yq '.services[].host' <"$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml)
  fi
  #####################################################################################
  #### discover upstreams if canary plugin is used in the service #####################
  #####################################################################################
  CANUPS=$(yq '.services[]|select(.plugins[]|.name =="canary")|.plugins[]|select(.name == "canary")|.config.upstream_host' <"$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml)
  if [[ ! -z "$(echo $CANUPS|tr " " "\n"|sed '/^$/d')" ]];then
    UPSTNM="$UPSTNM $CANUPS"
  fi
  ###############################################################################
  #### create a single file for all the upstreams discovered for a service  #####
  ###############################################################################
  ucount=0
  while read upstream 
  do
    yq '.upstreams| map(select(.name == "'$upstream'"))'< "$ENV"/"$ENV"_"$WORKSPACE".yaml > "$ENV"/"$ENV"_"$WORKSPACE"_"$service"_tmp-upstr.yaml
    if [[ ! -z "$(yq '.[]' "$ENV"/"$ENV"_"$WORKSPACE"_"$service"_tmp-upstr.yaml)" ]];then
       cat "$ENV"/"$ENV"_"$WORKSPACE"_"$service"_tmp-upstr.yaml >>"$ENV"/"$ENV"_"$WORKSPACE"_"$service"_upstreams.yaml
       ((ucount++))
    else
       echo "info: Service ('$service') upstream ('$upstream') not found!" >>"$ENV"/"$ENV"_"$WORKSPACE".logs
    fi
  done<<<"$(echo $UPSTNM|tr " " "\n"|sed '/^$/d')"
  if [[ "$ucount" -le 0 ]];then
    echo "info: No Kong upstream for service ('$service')! Service host is the backend url ('$UPSTNM')." >>"$ENV"/"$ENV"_"$WORKSPACE".logs
  else
    yq -i '{"upstreams": .}' "$ENV"/"$ENV"_"$WORKSPACE"_"$service"_upstreams.yaml
  fi
cat >"$ENV"/"$service"_tag.yaml<<EOL
_format_version: "1.1"
_info:
 defaults: {}
 select_tags:
 - "$service" 
_workspace: "$WORKSPACE"
EOL
  cat "$ENV"/"$service"_tag.yaml "$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml "$ENV"/"$ENV"_"$WORKSPACE"_"$service"_upstreams.yaml >"$ENV"/"$ENV"_"$WORKSPACE"_"$service"_temp.yaml 2>/dev/null
###########################################
#### final service file is generated  #####
###########################################
mv "$ENV"/"$ENV"_"$WORKSPACE"_"$service"_temp.yaml "$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml
deck validate -s "$ENV"/"$ENV"_"$WORKSPACE"_"$service".yaml 2>>"$ENV"/"$ENV"_"$WORKSPACE".logs
rm "$ENV"/*"$service"_*
done<"$ENV"/"$ENV"_"$WORKSPACE".services
#done<<<"$(echo $SVCS|sed -e 's/^ *//g;s/ *$//g'|tr " " "\n"|sed '/^$/d')"
rm "$ENV"/"$ENV"_"$WORKSPACE".services 2>/dev/null
rm "$ENV"/"$ENV"_"$WORKSPACE".yaml 2>/dev/null
