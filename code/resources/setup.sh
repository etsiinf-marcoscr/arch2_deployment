#!/bin/bash
#the two lines below are new for Amazon Linux2
#curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
#unzip awscliv2.zip
#sudo ./aws/install
#rm awscliv2.zip
#pip3 install boto3

echo Please enter a valid IP address:
read ip_address
echo IP address:$ip_address
echo Please wait...
#sudo pip install --upgrade awscli
bucket=`aws s3api list-buckets --query "Buckets[].Name" | grep s3bucket | tr -d ',' | sed -e 's/"//g' | xargs`
apigateway=`aws apigateway get-rest-apis | grep id | cut -f2- -d: | tr -d ',' | xargs`
echo $apigateway
FILE_PATH="/home/ec2-user/environment/resources/public_policy.json"
FILE_PATH_2="/home/ec2-user/environment/resources/permissions.py"
FILE_PATH_3="/home/ec2-user/environment/resources/setup.sh"
sed -i "s/<FMI_1>/$bucket/g" $FILE_PATH
sed -i "s/<FMI_2>/$ip_address/g" $FILE_PATH
sed -i "s/<FMI>/$bucket/g" $FILE_PATH_2

aws s3 cp ./resources/website s3://$bucket/ --recursive --cache-control "max-age=0"

python3 /home/ec2-user/environment/resources/permissions.py
python3 /home/ec2-user/environment/resources/seed.py

