#!/bin/sh
#Input:  Qubole Service Account,
#	 Credentials file for the customer's account
#        ProjectId
#        Defloc - Google Storage bucket for use by Qubole
#Output: Compute service account:compute.admin, read access to defloc
#        Instance service account:compute.admin,storage.admin
#        Qubole customer service account will be stored in $COMPUTE_SERVICE_ACCOUNT_FOR_QUBOLE
#        Instance service account will be stored in $INSTANCE_SERVICE_ACCOUNT_FOR_QUBOLE
#Run the script as 'source setup_service_accounts.sh' since we want to run the script in the calling shell to be able to access environment variables set by the script
#Usage: source setup_service_accounts.sh --qubole_sa=<qubole_service_account> --credentials_file=<customer_json_credentials_file> --project=<customer_ProjectID> --defloc=<google_storage_bucket_for_qubole>
#Sample Invocation: source setup_service_accounts.sh --qubole_sa=qds1-618@testgcp-218818.iam.gserviceaccount.com --credentials_file=gcp-key.json --project=qubole-gce --defloc=gs://vs-test

while [ "$#" -gt 0 ]; do
  case "$1" in
    -q) qubole_sa="$2"; shift 2;;
    -c) credentials_file="$2"; shift 2;;
    -r) roles="$2"; shift 2;;
    -i) inst_impersonation_roles="$2"; shift 2;;
    -p) project="$2"; shift 2;;
    -d) defloc="$2"; shift 2;;

    --qubole_sa=*) qubole_sa="${1#*=}"; shift 1;;
    --credentials_file=*) credentials_file="${1#*=}"; shift 1;;
    --roles=*) roles="${1#*=}"; shift 1;;
    --inst_impersonation_roles=*) inst_impersonation_roles="${1#*=}"; shift 1;;
    --project*) project="${1#*=}"; shift 1;;
    --defloc*) defloc="${1#*=}"; shift 1;;
    --qubole_sa|--credentials_file|--roles|--defloc|--project) echo "$1 requires an argument" >&2; echo "Script execution unsuccessful. Exiting...";return;;

    -*) echo "unknown option: $1" >&2; return;;
    *) handle_argument "$1"; shift 1;;
  esac
done

client_email_key="client_email"
project_key="project_id"
while IFS=":" read key val
do
    k=`echo $key | xargs | tr -d '"'`
    if [ $k == $client_email_key ]; then
        service_account=`echo $val | tr -d '"' | tr -d ','`
        domain=${service_account##*@}
    fi
    #if [ $k == $project_key ]; then
        #project=`echo $val | tr -d '"' | tr -d ','`
    #fi
done < $credentials_file

if [ -z "${roles}" ]
then
      roles="roles/iam.serviceAccountUser;roles/iam.serviceAccountTokenCreator"
else
      echo "Specified roles are [${roles}]"
fi

if [ -z "${inst_impersonation_roles}" ]
then
      inst_impersonation_roles="roles/iam.serviceAccountUser"
else
      echo "Specified inst_impersonation_roles are [${inst_impersonation_roles}]"
fi

echo "---------------------------------"
echo "$(date -u): Activating project [${project}]"
out="$(gcloud config set project ${project} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "Error activating project [${project}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Activating service account [${service_account}]"
out="$(gcloud auth activate-service-account --key-file=${credentials_file} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error activating service account [${service_account}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi

part1=$(echo $qubole_sa | awk -F"@" '{print $1}')
compute_sa="${part1}-comp" 
storage_sa="${part1}-inst" 
compute_sa_str=${compute_sa}@${domain}
storage_sa_str=${storage_sa}@${domain}
COMPUTE_SERVICE_ACCOUNT_FOR_QUBOLE=$compute_sa_str
INSTANCE_SERVICE_ACCOUNT_FOR_QUBOLE=$storage_sa_str

must_create_csa=true
must_create_ssa=true
echo "---------------------------------"
echo "$(date -u): Checking if compute service account [${compute_sa_str}] exists..."
out="$(gcloud iam service-accounts describe ${compute_sa_str} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "$(date -u): Compute service account [${compute_sa_str}] doesn't exist."
else
    echo "$(date -u): Compute service account [${compute_sa_str}] exists. Skipping creation."
    must_create_csa=false
fi
echo "---------------------------------"

echo "$(date -u): Checking if storage service account [${storage_sa_str}] exists..."
out="$(gcloud iam service-accounts describe ${storage_sa_str} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "$(date -u): Storage service account [${storage_sa_str}] doesn't exist."
else
    echo "$(date -u): Storage service account [${storage_sa_str}] exists. Skipping creation."
    must_create_ssa=false
fi
echo "---------------------------------"

if [ "$must_create_csa" = true ]; then
    echo "$(date -u): Creating compute service account [${compute_sa}]"
    out="$(gcloud iam service-accounts create ${compute_sa} 2>&1)"
    if [ ${PIPESTATUS[0]} -ne 0 ]
    then
        echo "$(date -u): Error creating compute service account [${compute_sa}]"
        echo "${out}" >&2
        echo "---------------------------------"
        echo "Script execution unsuccessful. Exiting...";return
    else
        echo "$(date -u): Successful..."
    fi
fi
echo "---------------------------------"

if [ "$must_create_ssa" = true ]; then
    echo "$(date -u): Creating instance service account [${storage_sa}]"
    out="$(gcloud iam service-accounts create ${storage_sa} 2>&1)"
    if [ ${PIPESTATUS[0]} -ne 0 ]
    then
        echo "$(date -u): Error creating instance service account [${compute_sa}]"
        echo "${out}" >&2
        echo "---------------------------------"
        echo "Script execution unsuccessful. Exiting...";return
    else
        echo "$(date -u): Successful..."
    fi
fi

for role in $(echo $roles | sed "s/;/ /g")
do
    echo "---------------------------------"
    echo "$(date -u): Adding [${qubole_sa}] as an impersonator on qubole customer service account [${compute_sa}] with role [${role}]"
    out="$(gcloud iam service-accounts add-iam-policy-binding ${compute_sa}@${domain} --member=serviceAccount:${qubole_sa} --role=${role} 2>&1)"
    if [ ${PIPESTATUS[0]} -ne 0 ]
    then
        echo "$(date -u): Error adding [${qubole_sa}] as an impersonator on [${compute_sa}]"
        echo "${out}" >&2
        echo "---------------------------------"
        echo "Script execution unsuccessful. Exiting...";return
    else
	echo "$(date -u): Successful..."
    fi
done

for role in $(echo $inst_impersonation_roles | sed "s/;/ /g")
do
  echo "---------------------------------"
  echo "$(date -u): Adding [${compute_sa_str}] as an impersonator on instance service account [${storage_sa_str}] with role [${role}]"
  out="$(gcloud iam service-accounts add-iam-policy-binding ${storage_sa}@${domain} --member=serviceAccount:${compute_sa_str} --role=${role} 2>&1)"
  if [ ${PIPESTATUS[0]} -ne 0 ]
  then
    echo "$(date -u): Error adding [${compute_sa_str}] as an impersonator on [${storage_sa_str}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
  else
  echo "$(date -u): Successful..."
  fi
done

for role in $(echo $inst_impersonation_roles | sed "s/;/ /g")
do
  echo "---------------------------------"
  echo "$(date -u): Adding [${storage_sa_str}] as an impersonator on instance service account [${storage_sa_str}] with role [${role}]"
  out="$(gcloud iam service-accounts add-iam-policy-binding ${storage_sa}@${domain} --member=serviceAccount:${storage_sa_str} --role=${role} 2>&1)"
  if [ ${PIPESTATUS[0]} -ne 0 ]
  then
    echo "$(date -u): Error adding [${storage_sa_str}] as an impersonator on [${storage_sa_str}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
  else
  echo "$(date -u): Successful..."
  fi
done


echo "---------------------------------"
echo "$(date -u): Assigning compute admin privileges to qubole customer service account [${compute_sa_str}]"
out="$(gcloud projects add-iam-policy-binding ${project} --member=serviceAccount:${compute_sa_str}  --role=roles/compute.admin 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error granting role roles/compute.admin to [${compute_sa_str}] on project [${project}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Assigning compute admin privileges to instance service account [${storage_sa_str}]"
out="$(gcloud projects add-iam-policy-binding ${project} --member="serviceAccount:${storage_sa_str}"  --role='roles/compute.admin' 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error granting role roles/compute.admin to [${storage_sa_str}] on project [${project}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi


echo "---------------------------------"
echo "$(date -u): Assigning storage admin privileges to compute service account [${compute_sa_str}]"
out="$(gcloud projects add-iam-policy-binding ${project} --member="serviceAccount:${compute_sa_str}" --role='roles/storage.admin' 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
  echo "$(date -u): Error granting role roles/storage.admin to [${compute_sa_str}] on project [${project}]"
  echo "${out}" >&2
  echo "---------------------------------"
  echo "Script execution unsuccessful. Exiting...";return
else
  echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Assigning storage admin privileges to instance service account [${storage_sa_str}]"
out="$(gcloud projects add-iam-policy-binding ${project} --member="serviceAccount:${storage_sa_str}" --role='roles/storage.admin' 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
  echo "$(date -u): Error granting role roles/storage.admin to [${storage_sa_str}] on project [${project}]"
  echo "${out}" >&2
  echo "---------------------------------"
  echo "Script execution unsuccessful. Exiting...";return
else
  echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Assigning read privileges to compute service account [${compute_sa_str}] on [${defloc}]"
out="$(gsutil acl ch -u ${compute_sa_str}:R ${defloc} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error granting read privileges to [${compute_sa_str}] on bucket [${defloc}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Assigning write privileges to compute service account [${compute_sa_str}] on [${defloc}]"
out="$(gsutil acl ch -u ${compute_sa_str}:W ${defloc} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error granting write privileges to [${compute_sa_str}] on bucket [${defloc}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Assigning read privileges to instance service account [${storage_sa_str}] on [${defloc}]"
out="$(gsutil acl ch -u ${storage_sa_str}:R ${defloc} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error granting read privileges to [${storage_sa_str}] on bucket [${defloc}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi

echo "---------------------------------"
echo "$(date -u): Assigning write privileges to instance service account [${storage_sa_str}] on [${defloc}]"
out="$(gsutil acl ch -u ${storage_sa_str}:W ${defloc} 2>&1)"
if [ ${PIPESTATUS[0]} -ne 0 ]
then
    echo "$(date -u): Error granting write privileges to [${storage_sa_str}] on bucket [${defloc}]"
    echo "${out}" >&2
    echo "---------------------------------"
    echo "Script execution unsuccessful. Exiting...";return
else
    echo "$(date -u): Successful..."
fi
echo "$(date -u): Script execution complete"
echo "---------------------------------"
echo "Compute Service Account: ${compute_sa_str}"
echo "Storage Service Account: ${storage_sa_str}"
echo "---------------------------------"
