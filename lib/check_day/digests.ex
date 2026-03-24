defmodule CheckDay.Digests do
  use Ash.Domain,
    otp_app: :check_day

  resources do
    resource CheckDay.Digests.DigestBlock
    resource CheckDay.Digests.DigestRun
  end
end
