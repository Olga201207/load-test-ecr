variable "region" {
  description = "AWS 리전. loglens-infra(EKS)와 같은 리전이어야 노드가 리전 간 전송 없이 pull 한다."
  type        = string
  default     = "ap-northeast-2"
}

variable "repository_name" {
  description = "ECR 리포지터리 이름"
  type        = string
  default     = "loglens-sut"
}

variable "max_image_count" {
  description = "남겨 둘 최신 이미지 수. 이보다 오래된 이미지는 수명 주기 정책이 삭제한다 (롤백 가능 범위)."
  type        = number
  default     = 10

  validation {
    condition     = var.max_image_count >= 1
    error_message = "max_image_count 는 1 이상이어야 합니다."
  }
}

variable "tags" {
  description = "모든 AWS 리소스에 추가로 붙일 태그"
  type        = map(string)
  default     = {}
}
