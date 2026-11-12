# Class API on AWS with Terraform

Deploys the class Flask API to ECS Fargate in **us-east-2** with a public
Application Load Balancer. Terraform prints `dns_name` and `api_url`.

## Resources

- Dedicated VPC, two public subnets in separate availability zones, internet gateway and routes.
- Public HTTP listener on port 80; the container's port 8000 accepts traffic only from the load balancer.
- One Fargate task: 0.25 vCPU, 512 MiB memory, Linux/X86_64.
- ECS cluster, task definition, service, target group and health checks.
- Execution role limited to writing container logs; seven-day CloudWatch log retention.

Image: `bubbaj/it4200-fall-2026:2.49.0`, pinned by its verified AMD64 digest
in `main.tf`. The Flask command disables debug mode. This is a classroom demo,
not a production web server. HTTP is unencrypted; do not submit sensitive data.
Scores stored inside the container are lost if the task is replaced.

The task has a public IP for pulling the public image without a NAT gateway.
Its security group blocks direct public inbound traffic. Fargate, the load
balancer, public IPv4 addresses, logs and data transfer consume AWS credits
or incur charges while running.

## Authenticate and plan

```sh
aws login --region us-east-2 --profile class-aws
aws sts get-caller-identity --profile class-aws
terraform init
terraform fmt -check
terraform validate
terraform plan -out=deployment.tfplan
```

Review the plan before provisioning. Then:

```sh
terraform apply deployment.tfplan
terraform output -raw dns_name
terraform output -raw api_url
```

## Verify and demonstrate in class

```sh
API_URL=$(terraform output -raw api_url)
curl --fail "$API_URL/"
curl --fail "$API_URL/random-fact"
aws ecs describe-services --region us-east-2 --profile class-aws \
  --cluster "$(terraform output -raw cluster_name)" \
  --services "$(terraform output -raw service_name)" \
  --query 'services[].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}'
aws elbv2 describe-target-health --region us-east-2 --profile class-aws \
  --target-group-arn "$(terraform output -raw target_group_arn)"
```

Show the live URL and a running task in the ECS console during class. Submit the
GitHub link to this Terraform code. A successful plan is not proof of deployment;
confirm a healthy target and a successful HTTP response after applying.

## Clean up after the demonstration

```sh
terraform plan -destroy
terraform destroy
```

Review and confirm cleanup when ready. Keep the local state files until cleanup
is complete. Never commit credentials, `.terraform/`, state, or saved plan files.
Commit `main.tf`, this README, `.gitignore`, and `.terraform.lock.hcl`.
