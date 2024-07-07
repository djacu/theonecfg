let
  yubikeys = {
    mini = "age1yubikey1qtlkg3n7tdwzqe22tc079nrm0ylptu4qlw8vmydpqsuc0nf8ytjfjt2p9kh";
  };

  allYubikeys = builtins.attrValues yubikeys;
in
{
  "cassiterite_djacu_ssh_private.age".publicKeys = allYubikeys;
  "cassiterite_djacu_ssh_public.age".publicKeys = allYubikeys;
}
