// container_app_env.tf

# The ACA Environment has been moved from Platform LZ to project level.
# Each project creates its own ACA Environment inside its effective runner
# subnet (platform VNet or BYO VNet).  See §5.4.1 and §14#6 in the
# Target Architecture Spec.
#
# The Platform LZ continues to provide the shared infrastructure that
# project-level ACA Environments consume:
#   - ACR (container images)
#   - Log Analytics workspace (logging)
#   - container-run UAMI (image pull + secret access)
#   - Private DNS zones (name resolution)
#   - Platform VNet + subnets (network substrate in platform mode)
#
# Migration from a previous deployment where the ACA Environment lived
# in the LZ state:
#   terraform state rm 'module.aca[0]'
# Then re-apply the project module, which will recreate the ACA
# Environment at the project level.
