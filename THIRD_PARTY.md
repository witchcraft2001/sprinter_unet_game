# Third-party components

## Z80core.js — `tools/harness/z80core.js`

JavaScript Z80 interpreter by Molly Howell, MIT license
(`tools/harness/LICENSE.Z80core`). Vendored unchanged from
`sprinter-rtl8019a/tools/exe-harness/Z80core.js`. Used only by the host test
stand; never shipped. Do not edit it in place; `tests/host/test_third_party.py`
checks the pinned SHA-256:

```
44a0398fdf763aca6cd3608777f4b30aa53ceb4d0ec2f7234422ceb44980def0
```

## libman — `third_party/libman` (git submodule)

Sprinter DLL manager and the `sprinter-mkdll` builder,
`https://github.com/witchcraft2001/sprinter-libman.git`, pinned by the
submodule commit (`f042e33`, libman 1.4; the DLLs are built for target 1.3).
The SDK loader (`sdk/loader/ugload.asm`) and the M stand programs include
`third_party/libman/libman/libman.asm` into the application; the DLLs never
contain libman code. The repository has no license file; this project only
references it as a submodule and never copies its sources. The SDK reads the
internal `LIBMAN.lib_table` layout and asserts `LIBMAN.VERSION`.
