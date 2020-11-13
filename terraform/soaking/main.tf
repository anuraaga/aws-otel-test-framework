# ------------------------------------------------------------------------
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
# -------------------------------------------------------------------------
provider "aws" {
  region  = var.region
}

module "common" {
  source = "../common"
}

# launch ec2
module "ec2_setup" {
  source = "../ec2"

  ami_family = var.ami_family
  amis = var.amis
  testing_ami = var.testing_ami
  aoc_version = var.aoc_version
  region = var.region
  testcase = var.testcase
  sample_app_image = var.soaking_data_emitter_image
  validation_config = var.validation_config
  skip_validation = true

  # soaking test config
  soaking_compose_file = "../templates/defaults/soaking_docker_compose.tpl"
  soaking_data_mode = var.soaking_data_mode
  soaking_data_rate = var.soaking_data_rate
  soaking_data_type = var.soaking_data_type
}

locals {
  selected_ami = var.amis[var.testing_ami]
  ami_family = var.ami_family[local.selected_ami["family"]]
  instance_type = local.ami_family["instance_type"]
  login_user = local.ami_family["login_user"]
  connection_type = local.ami_family["connection_type"]
}

## install cwagent on the instance to collect metric from otel-collector
data "template_file" "cwagent_config" {
  template = file(local.ami_family["soaking_cwagent_config"])

  vars = {
    soaking_metric_namespace = var.soaking_metric_namespace
  }
}

resource "null_resource" "install_cwagent" {
  // copy cwagent config to the instance
  provisioner "file" {
    content = data.template_file.cwagent_config.rendered
    destination = local.ami_family["soaking_cwagent_config_destination"]

    connection {
      type = local.connection_type
      user = local.login_user
      private_key = local.connection_type == "ssh" ? module.ec2_setup.private_key: null
      password = local.connection_type == "winrm" ? rsadecrypt(module.ec2_setup.instance_password_data, module.ec2_setup.private_key) : null
      host = module.ec2_setup.collector_instance_public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      local.ami_family["cwagent_download_command"],
      local.ami_family["cwagent_start_command"]
    ]

    connection {
      type = local.connection_type
      user = local.login_user
      private_key = local.connection_type == "ssh" ? module.ec2_setup.private_key : null
      password = local.connection_type == "winrm" ? rsadecrypt(module.ec2_setup.instance_password_data, module.ec2_setup.private_key) : null
      host = module.ec2_setup.collector_instance_public_ip
    }
  }
}

# create alarm
## create cloudwatch alarm base on the metrics emitted by cwagent
# wait 2 minute for the metrics to be available on cloudwatch
resource "time_sleep" "wait_2_minutes" {
  depends_on = [null_resource.install_cwagent]

  create_duration = "120s"
}
# cpu alarm
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  depends_on = [time_sleep.wait_2_minutes]
  alarm_name = "otel-soaking-cpu-alarm-${module.common.testing_id}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = 2
  threshold = "50"

  metric_query {
    id = "cpu"
    return_data = true

    metric {
      metric_name = local.ami_family["soaking_cpu_metric_name"]
      namespace = var.soaking_metric_namespace
      period = 60
      stat = "Average"
      unit = "Percent"

      # use this dimension to identify each test
      dimensions = {
        InstanceId = module.ec2_setup.collector_instance_id
        exe = "aws-otel-collector"
        process_name = "aws-otel-collector"
      }
    }
  }
}

##########################################
# Validation
##########################################
module "validator" {
  source = "../validation"

  validation_config = var.validation_config
  region = var.region
  testing_id = module.common.testing_id
  alarm_names = aws_cloudwatch_metric_alarm.cpu_alarm.alarm_name

  depends_on = [aws_cloudwatch_metric_alarm.cpu_alarm]
}
