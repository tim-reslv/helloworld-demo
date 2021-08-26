#!/bin/bash

DEMO_NAMESPACE=helloworld
APPLABEL=helloworld
GIT_URL=https://github.com/tim-reslv/helloworld-demo
me="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"

# define GKE Server & Client cluster context
export SERVER_CLUSTER=$(kubectl config view -ojson | jq -r '.clusters[].name' | grep east2-a_gke)
export CLIENT_CLUSTER=$(kubectl config view -ojson | jq -r '.clusters[].name' | grep onprem)


function cluster_info {

  echo "--------------------------------------------------------------------"
  echo -e "SERVER_CLUSTER:\t\t${SERVER_CLUSTER}"
  echo -e "CLIENT_CLUSTER:\t\t${CLIENT_CLUSTER}"
  echo "--------------------------------------------------------------------"

  INGRESS_IP=`kubectl --context ${SERVER_CLUSTER} -n istio-system get svc istio-ingressgateway |awk '{print $4}'|grep -v EXTERNAL-IP`
  echo ""
  echo "--------------------------------------------------------------------"
  echo "Frontend URL: http://${APPLABEL}.${INGRESS_IP}.nip.io"
  echo "--------------------------------------------------------------------"
}

function remove_namespace {

  if (kubectl --context="$1" get namespace $2 >> /dev/null 2>&1); then
    echo "Remove existing namespace"
    echo "Cluster: ${1} namespace $2 removing"
        kubectl --context="$1" delete namespace $2
        echo ""
  else
    echo "Cluster: ${1} namespace $2 doesn't exist"
        echo ""
  fi

}

# Function to create namespace
function create_namespace {

  if (kubectl --context="$1" get namespace $2 >> /dev/null 2>&1); then
    remove_namespace $1 $2
        kubectl --context="$1" create namespace $2
        kubectl --context $1 label namespace $2 istio-injection- istio.io/rev=asm-195-2 --overwrite
        echo ""
  else
    echo "Cluster: ${1} creating namespace $2"
        kubectl --context="$1" create namespace $2
        kubectl --context $1 label namespace $2 istio-injection- istio.io/rev=asm-195-2 --overwrite
        echo ""
  fi

}

function check {

  echo "Cluster: $1"
  kubectl --context="$1" -n $2 get pod
  echo ""

}

function init {

  create_namespace $SERVER_CLUSTER $DEMO_NAMESPACE
  create_namespace $CLIENT_CLUSTER $DEMO_NAMESPACE

  # Git clone demo
  tmp_dir=$(mktemp -d)
  cd $tmp_dir
  git clone ${GIT_URL}
  cd `echo $GIT_URL|awk -F'/' '{print $NF}'`

  # Create Frontend Ingress
  INGRESS_IP=`kubectl --context ${SERVER_CLUSTER} -n istio-system get svc istio-ingressgateway |awk '{print $4}'|grep -v EXTERNAL-IP`

  sed -i "s/34.96.206.204/$INGRESS_IP/g" ingress.yaml

  # Deploy application to SERVER_CLUSTER
  kubectl --context ${SERVER_CLUSTER} -n ${DEMO_NAMESPACE} apply -f deployment1.yaml
  kubectl --context ${SERVER_CLUSTER} -n ${DEMO_NAMESPACE} apply -f svc.yaml
  kubectl --context ${SERVER_CLUSTER} -n ${DEMO_NAMESPACE} apply -f ingress.yaml



  # Deploy application to CLIENT_CLUSTER
  kubectl --context ${CLIENT_CLUSTER} -n ${DEMO_NAMESPACE} apply -f deployment2.yaml
  kubectl --context ${CLIENT_CLUSTER} -n ${DEMO_NAMESPACE} apply -f svc.yaml

  echo ""
  echo ""
  echo "--------------------------------------------------------------------"
  echo "Frontend URL: http://${APPLABEL}.${INGRESS_IP}.nip.io"
  echo "--------------------------------------------------------------------"

  cd /tmp
  rm -rf $tmp_dir

  echo "waiting for pod ready"
  while [[ $(kubectl --context ${SERVER_CLUSTER} -n $DEMO_NAMESPACE get pods -l app=${APPLABEL} -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo -n . && sleep 1; done

  check $SERVER_CLUSTER $DEMO_NAMESPACE
  check $CLIENT_CLUSTER $DEMO_NAMESPACE

}

function migrate_pod {

  tmp_dir=$(mktemp -d)
  cd $tmp_dir
  git clone ${GIT_URL} >> /dev/null 2>&1
  cd `echo $GIT_URL|awk -F'/' '{print $NF}'`

  if [[ $1 == "c2o" ]]; then
    echo "Create ${2} to $CLIENT_CLUSTER"
    kubectl --context ${CLIENT_CLUSTER} -n $DEMO_NAMESPACE apply -f deployment${2:1}.yaml
    echo "waiting for pod ready"
    while [[ $(kubectl --context ${CLIENT_CLUSTER} -n $DEMO_NAMESPACE get pods -l app=${APPLABEL} -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo -n . && sleep 1; done
    echo ""
    echo "Remove ${2} from $SERVER_CLUSTER"
    kubectl --context ${SERVER_CLUSTER} -n $DEMO_NAMESPACE delete -f deployment${2:1}.yaml
    echo ""
  elif [[ $1 == "o2c" ]]; then
    echo "Create ${2} to $SERVER_CLUSTER"
    kubectl --context ${SERVER_CLUSTER} -n $DEMO_NAMESPACE apply -f deployment${2:1}.yaml
    echo "waiting for pod ready"
    while [[ $(kubectl --context ${SERVER_CLUSTER} -n $DEMO_NAMESPACE get pods -l app=${APPLABEL} -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo -n . && sleep 1; done
    echo ""
    echo "Remove ${2} from $CLIENT_CLUSTER"
    kubectl --context ${CLIENT_CLUSTER} -n $DEMO_NAMESPACE delete -f deployment${2:1}.yaml
    echo ""
  else
    echo "Invalid option: --migrate [c2o|o2c]"
  fi

  rm -rf $tmp_dir
}

function deploy {

  # Git clone demo
  tmp_dir=$(mktemp -d)
  cd $tmp_dir
  git clone ${GIT_URL} >> /dev/null 2>&1
  cd ${tmp_dir}/`echo $GIT_URL|awk -F'/' '{print $NF}'`


  if [[ $1 != "${CLIENT_CLUSTER}" && $1 != "${SERVER_CLUSTER}" ]]; then
    echo "Cluster name is invalid!"
    echo "./${me} --info to get clustername"
    exit
  fi

  if [[ ${2,,} == "v1" ]]; then
    kubectl --context ${1} -n $DEMO_NAMESPACE apply -f deployment1.yaml
  elif [[ ${2,,} == "v2" ]]; then
    kubectl --context ${1} -n $DEMO_NAMESPACE apply -f deployment2.yaml
  elif [[ ${2,,} == "all" ]]; then
    kubectl --context ${1} -n $DEMO_NAMESPACE apply -f deployment1.yaml
    kubectl --context ${1} -n $DEMO_NAMESPACE apply -f deployment2.yaml
  else
    echo "Invalid option: --deploy clustername [v1|v2|all]"
  fi

  cd /tmp
  rm -rf $tmp_dir

}

function remove {

  # Git clone demo
  tmp_dir=$(mktemp -d)
  cd $tmp_dir
  git clone ${GIT_URL} >> /dev/null 2>&1
  cd ${tmp_dir}/`echo $GIT_URL|awk -F'/' '{print $NF}'`


  if [[ $1 != "${CLIENT_CLUSTER}" && $1 != "${SERVER_CLUSTER}" ]]; then
    echo "Cluster name is invalid!"
    echo "./${me} --info to get clustername"
    exit
  fi

  if [[ ${2,,} == "v1" ]]; then
    kubectl --context ${1} -n $DEMO_NAMESPACE delete -f deployment1.yaml
  elif [[ ${2,,} == "v2" ]]; then
    kubectl --context ${1} -n $DEMO_NAMESPACE delete -f deployment2.yaml
  elif [[ ${2,,} == "all" ]]; then
    kubectl --context ${1} -n $DEMO_NAMESPACE delete -f deployment1.yaml
    kubectl --context ${1} -n $DEMO_NAMESPACE delete -f deployment2.yaml
  else
    echo "Invalid option: --remove clustername [v1|v2|all]"
  fi

  cd /tmp
  rm -rf $tmp_dir

}


function endpoint_secret {

  if [[ $2 == "create" ]]; then
    if [[ $1 == "${CLIENT_CLUSTER}" ]]; then
          export CLUSTERNAME=`cat ~/clusters/gke_asm/asm-195-2-manifest-raw.yaml |grep clusterName|awk '{print $2}'`
      istioctl x create-remote-secret \
        --context="${SERVER_CLUSTER}" \
        --name=${CLUSTERNAME} | \
        kubectl apply -f - --context="${CLIENT_CLUSTER}"
      kubectl --context="${CLIENT_CLUSTER}" -n istio-system get secret |grep istio-remote-secret |awk '{print $1}'
    elif [[ $1 == "${SERVER_CLUSTER}" ]]; then
      istioctl x create-remote-secret \
        --context="${CLIENT_CLUSTER}" \
        --name=${CLIENT_CLUSTER} | \
        kubectl apply -f - --context="${SERVER_CLUSTER}"

      kubectl --context="${SERVER_CLUSTER}" -n istio-system get secret |grep istio-remote-secret |awk '{print $1}'
        else
          echo "Invalid option: --endpoint clustername [create|delete]"
          echo "./${me} --info to get clustername"
    fi
  elif [[ $2 == "delete" ]]; then
    if [[ ${1}x != "x" ]]; then
      REMOTE_SECRET=`kubectl --context="${1}" -n istio-system get secret |grep istio-remote-secret |awk '{print $1}'`
      kubectl --context="${1}" -n istio-system delete secret ${REMOTE_SECRET}
    else
      echo "Invalid option: --endpoint clustername [create|delete]"
      echo "./${me} --info to get clustername"
    fi
  else
    echo "Invalid option: --endpoint clustername [create|delete]"
  fi

}

# parse the flag options (and their arguments)
while [[ $# -gt 0 ]];
do
    opt="$1";
    shift;              #expose next argument
    case "$opt" in
        "--check" )
           check $SERVER_CLUSTER $DEMO_NAMESPACE
           check $CLIENT_CLUSTER $DEMO_NAMESPACE;;
        "--deploy" )
           CLUSTER=$1
           shift
           SERVICE=$1
           shift
           deploy $CLUSTER $SERVICE;;
        "--destroy" )
           remove_namespace $SERVER_CLUSTER $DEMO_NAMESPACE
           remove_namespace $CLIENT_CLUSTER $DEMO_NAMESPACE;;
        "--endpoint" )
           CLUSTER=$1
           shift
           ACTION=$1
           shift
           endpoint_secret $CLUSTER $ACTION;;
        "--help" )
		   echo -e "**************************************************************"
		   echo -e "*                                                            *"
   		   echo -e "*            Anthos Demo                                     *"
		   echo -e "*                                                            *"
		   echo -e "**************************************************************"		   
           echo -e ""
           echo -e "--check\t\t check application pod status. \n"
           echo -e "--deploy\t deploy service to cluster. --deploy clustername [v1|v2|all]\n"
           echo -e "--destroy\t remove ${DEMO_NAMESPACE} application and namespace. \n"
           echo -e "--endpoint\t cluster endpoint secret operation. --endpoint clustername [create|delete] \n"
	   echo -e "--help\t\t this help menu. \n"
           echo -e "--info\t\t show cluster name and frontend URL. \n"
           echo -e "--init\t\t create ${DEMO_NAMESPACE} namespace and deploy application. \n"
           echo -e "--migrate\t migrate ${DEMO_NAMESPACE} pod between clusters. --migrate [c2o|o2c] [v1|v2]\n"
           echo -e "--remove\t remove ${DEMO_NAMESPACE} service from cluster. --remove clustername [v1|v2|all]\n";;
        "--info" ) cluster_info;;
        "--init" )
           init;;
        "--migrate" )
           DIRECTION=$1
           shift
           SERVICE=$1
           shift
           migrate_pod $DIRECTION $SERVICE ;;
        "--remove" )
           CLUSTER=$1
           shift
           SERVICE=$1
           shift
           remove $CLUSTER $SERVICE;;
        *) echo >&2 "Invalid option: $@";
           echo "--help"
           exit 1;;
   esac
done
