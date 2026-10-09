###############################################################################
# loglens-ecr — SUT 이미지 저장소
#
# loglens-infra 와 생명주기가 다르다.
#   loglens-infra : 쓸 때 apply, 안 쓸 때 destroy 를 반복한다.
#   loglens-ecr   : 한 번 만들고 계속 유지한다. 이미지(롤백 대상)가 여기 쌓인다.
# 그래서 Terraform 상태를 분리했다. loglens-infra 를 destroy 해도 이 스택은 영향이 없다.
#
# EKS 노드 IAM 역할에는 EKS 모듈이 AmazonEC2ContainerRegistryReadOnly 를 이미 붙이므로
# 클러스터에서 이 리포지터리를 pull 하는 데 추가 설정이 필요 없다 (같은 계정/리전).
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 상태 파일은 local backend (terraform.tfstate). 이 디렉터리를 지우면 상태도 사라지므로
  # 상태 파일을 잃었을 때는 README 6절을 따라 import 한다.
}

provider "aws" {
  region = var.region

  # 자격증명은 코드에 넣지 않는다.
  # AWS_PROFILE / AWS_ACCESS_KEY_ID 등 표준 자격증명 체인을 사용한다.

  default_tags {
    tags = merge(
      {
        Project   = "loglens"
        Stack     = "loglens-ecr"
        ManagedBy = "terraform"
      },
      var.tags,
    )
  }
}

###############################################################################
# 리포지터리
###############################################################################

resource "aws_ecr_repository" "sut" {
  name = var.repository_name

  # 같은 태그로 덮어쓰지 못한다. 태그 = 특정 빌드로 고정되므로 이전 태그로 되돌리면 롤백이 된다.
  # 따라서 "latest" 같은 고정 태그는 두 번 push 할 수 없다. 버전/커밋 해시 태그를 쓴다 (README 3절).
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # 이미지가 남아 있으면 리포지터리를 지우지 않는다 (기본값이지만 의도를 드러내려고 명시).
  force_delete = false

  # 실수로 terraform destroy 해도 리포지터리가 지워지지 않게 막는다.
  # 정말 지우려면 이 블록을 지운 뒤 destroy 한다 (README 5절).
  lifecycle {
    prevent_destroy = true
  }
}

###############################################################################
# 수명 주기 정책: 최신 N개만 남긴다 (저장 요금 방지)
#
# tagStatus = any: 태그 유무와 상관없이 push 시각 기준 최신 N개를 남긴다.
# 태그 없는 이미지(빌드 실패 잔재, 멀티 아키텍처 매니페스트 조각 등)도 개수에 포함된다.
###############################################################################

resource "aws_ecr_lifecycle_policy" "sut" {
  repository = aws_ecr_repository.sut.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the latest ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
