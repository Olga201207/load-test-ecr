locals {
  # <account>.dkr.ecr.<region>.amazonaws.com
  registry = split("/", aws_ecr_repository.sut.repository_url)[0]
}

output "repository_url" {
  description = "이미지 주소 (태그 제외). k8s 매니페스트의 image 에 쓴다."
  value       = aws_ecr_repository.sut.repository_url
}

output "registry" {
  description = "레지스트리 호스트 (docker login 대상)"
  value       = local.registry
}

output "docker_login_command" {
  description = "docker login 명령 (Windows CMD / Git Bash 공통). 토큰은 12시간 유효하다."
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.registry}"
}

output "push_command_example" {
  description = "빌드/푸시 예시 (Windows CMD, loglens-sut 디렉터리에서). TAG 는 매번 새 값 (IMMUTABLE)."
  value       = <<-EOT
    set TAG=0.1.0
    docker build -t ${aws_ecr_repository.sut.repository_url}:%TAG% .
    docker push ${aws_ecr_repository.sut.repository_url}:%TAG%
  EOT
}
