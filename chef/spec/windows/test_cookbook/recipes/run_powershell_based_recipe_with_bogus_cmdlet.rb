test_cookbook_encode do
  action :url_encode
  message "encode first"
end

test_cookbook_echo do
  action :echo_text
  message "then echo"
end

test_cookbook_encode do
  action :fail_with_bogus_cmdlet
  message "encode failed"
end

test_cookbook_encode do
  action :url_encode
  message "encode after fail"
end

test_cookbook_echo do
  action :echo_text
  message "echo again"
end