resource "aws_iam_instance_profile" "ecs" {
  name = "${var.app_name}-${var.environment}-ecs-instance"
  role = "${aws_iam_role.ecs_instance.name}"
}

resource "aws_iam_policy_attachment" "ecs_instance" {
  name       = "${var.app_name}-${var.environment}-ecs-instance"
  roles      = ["${aws_iam_role.ecs_instance.name}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role" "ecs_instance" {
  name = "${var.app_name}-${var.environment}-ecs-instance"
  path = "/"

  assume_role_policy = <<EOF
{
    "Version": "2008-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
      }
    ]
}
EOF

  tags = {
    Environment = "${var.environment}"
    Application = "${var.app_name}"
  }
}

resource "aws_security_group" "ecs_instance" {
  name        = "${var.app_name}-ecs-instance"
  description = "container security group for ${var.app_name}"
  vpc_id      = "${var.vpc}"

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "TCP"
    security_groups = ["${aws_security_group.ecs_alb.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "${var.environment}"
    Application = "${var.app_name}"
  }
}

resource "aws_iam_policy_attachment" "fleet" {
  name       = "${var.app_name}-fleet"
  roles      = ["${aws_iam_role.fleet.name}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetRole"
}

resource "aws_iam_role" "fleet" {
  name = "${var.app_name}-fleet"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "spotfleet.amazonaws.com",
          "ec2.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  tags = {
    Environment = "${var.environment}"
    Application = "${var.app_name}"
  }
}

data "aws_region" "current" {}

resource "aws_spot_fleet_request" "main" {
  iam_fleet_role                      = "${aws_iam_role.fleet.arn}"
  spot_price                          = "${var.spot_prices[0]}"
  allocation_strategy                 = "${var.strategy}"
  target_capacity                     = "${var.instance_count}"
  terminate_instances_with_expiration = true
  valid_until                         = "${var.valid_until}"

  launch_specification {
    ami                    = "${var.ami}"
    instance_type          = "${var.instance_type}"
    spot_price             = "${var.spot_prices[0]}"
    subnet_id              = "${var.subnet_a}"
    vpc_security_group_ids = ["${aws_security_group.ecs_instance.id}"]
    iam_instance_profile   = "${aws_iam_instance_profile.ecs.name}"
    key_name               = "${var.key_name}"

    root_block_device = {
      volume_type = "gp2"
      volume_size = "${var.volume_size}"
    }

    user_data = <<USER_DATA
#!/bin/bash
set -eux
mkdir -p /etc/ecs
echo ECS_CLUSTER=${var.ecs_cluster_name} >> /etc/ecs/ecs.config
export PATH=/usr/local/bin:$PATH
yum -y install jq
easy_install pip
pip install awscli
aws configure set default.region ${data.aws_region.current.name}

cat <<EOF > /etc/init/spot-instance-termination-handler.conf
description "Start spot instance termination handler monitoring script"
author "BoltOps"
start on started ecs
script
echo \$\$ > /var/run/spot-instance-termination-handler.pid
exec /usr/local/bin/spot-instance-termination-handler.sh
end script
pre-start script
logger "[spot-instance-termination-handler.sh]: spot instance termination
notice handler started"
end script
EOF

cat <<EOF > /usr/local/bin/spot-instance-termination-handler.sh
#!/bin/bash
while sleep 5; do
if [ -z \$(curl -Isf http://169.254.169.254/latest/meta-data/spot/termination-time)]; then
/bin/false
else
logger "[spot-instance-termination-handler.sh]: spot instance termination notice detected"
STATUS=DRAINING
ECS_CLUSTER=\$(curl -s http://localhost:51678/v1/metadata | jq .Cluster | tr -d \")
CONTAINER_INSTANCE=\$(curl -s http://localhost:51678/v1/metadata | jq .ContainerInstanceArn | tr -d \")
logger "[spot-instance-termination-handler.sh]: putting instance in state \$STATUS"

/usr/local/bin/aws  ecs update-container-instances-state --cluster \$ECS_CLUSTER --container-instances \$CONTAINER_INSTANCE --status \$STATUS

logger "[spot-instance-termination-handler.sh]: putting myself to sleep..."
sleep 120 # exit loop as instance expires in 120 secs after terminating notification
fi
done
EOF

chmod +x /usr/local/bin/spot-instance-termination-handler.sh
USER_DATA
  }

  launch_specification {
    ami                    = "${var.ami}"
    instance_type          = "${var.instance_type}"
    spot_price             = "${var.spot_prices[1]}"
    subnet_id              = "${var.subnet_b}"
    vpc_security_group_ids = ["${aws_security_group.ecs_instance.id}"]
    iam_instance_profile   = "${aws_iam_instance_profile.ecs.name}"
    key_name               = "${var.key_name}"

    root_block_device = {
      volume_type = "gp2"
      volume_size = "${var.volume_size}"
    }

    user_data = <<USER_DATA
#!/bin/bash
set -eux
mkdir -p /etc/ecs
echo ECS_CLUSTER=${var.ecs_cluster_name} >> /etc/ecs/ecs.config
export PATH=/usr/local/bin:$PATH
yum -y install jq
easy_install pip
pip install awscli
aws configure set default.region ${data.aws_region.current.name}

cat <<EOF > /etc/init/spot-instance-termination-handler.conf
description "Start spot instance termination handler monitoring script"
author "BoltOps"
start on started ecs
script
echo \$\$ > /var/run/spot-instance-termination-handler.pid
exec /usr/local/bin/spot-instance-termination-handler.sh
end script
pre-start script
logger "[spot-instance-termination-handler.sh]: spot instance termination
notice handler started"
end script
EOF

cat <<EOF > /usr/local/bin/spot-instance-termination-handler.sh
#!/bin/bash
while sleep 5; do
if [ -z \$(curl -Isf http://169.254.169.254/latest/meta-data/spot/termination-time)]; then
/bin/false
else
logger "[spot-instance-termination-handler.sh]: spot instance termination notice detected"
STATUS=DRAINING
ECS_CLUSTER=\$(curl -s http://localhost:51678/v1/metadata | jq .Cluster | tr -d \")
CONTAINER_INSTANCE=\$(curl -s http://localhost:51678/v1/metadata | jq .ContainerInstanceArn | tr -d \")
logger "[spot-instance-termination-handler.sh]: putting instance in state \$STATUS"

/usr/local/bin/aws  ecs update-container-instances-state --cluster \$ECS_CLUSTER --container-instances \$CONTAINER_INSTANCE --status \$STATUS

logger "[spot-instance-termination-handler.sh]: putting myself to sleep..."
sleep 120 # exit loop as instance expires in 120 secs after terminating notification
fi
done
EOF

chmod +x /usr/local/bin/spot-instance-termination-handler.sh
USER_DATA
  }

  depends_on = ["aws_iam_policy_attachment.fleet"]
}
