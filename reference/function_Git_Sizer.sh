#!/bin/sh
GIT_SIZER_RESULT="GitSizerResult.txt"

copado -p "Download and install Git-Sizer"
wget https://github.com/github/git-sizer/releases/download/v1.5.0/git-sizer-1.5.0-linux-amd64.zip
unzip git-sizer-1.5.0-linux-amd64.zip -d sizer
export PATH=$PATH:/app/sizer

echo "******* - START - Cloning/fetching Repository"
copado -p "Cloning/fetching Repository"
copado-git-get $mainBranch
echo "******* - END - Cloning/fetching Repository"

echo "******* - START - Executing git Sizer"
copado -p "Executing Git Sizer"

git-sizer --verbose > $GIT_SIZER_RESULT
cat $GIT_SIZER_RESULT
echo "******* - END - Executing git Sizer"

echo "******* - Delete previous Git Sizer if exists - Executing git Sizer"
sf config set --global org-instance-url=$CF_SF_ENDPOINT target-org=$CF_SF_SESSIONID
QUERY_RESULT=$(sf data query --query "SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = '$repositoryRecordId' AND ContentDocument.Title = '$GIT_SIZER_RESULT'" --json)
CONTENT_ID=$(echo $QUERY_RESULT | jq -r '.result.records[0].ContentDocumentId')
if [ -n "$CONTENT_ID" ] && [ "$CONTENT_ID" != "null" ]; then
    sf data delete record --sobject ContentDocument --record-id "$CONTENT_ID"
fi

copado -p "Uploading Git Sizer Results"
copado --uploadfile $GIT_SIZER_RESULT --name $GIT_SIZER_RESULT
copado --uploadfile $GIT_SIZER_RESULT --name $GIT_SIZER_RESULT --parentid $repositoryRecordId